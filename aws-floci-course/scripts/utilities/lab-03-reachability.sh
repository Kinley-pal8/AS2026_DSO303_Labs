#!/usr/bin/env bash
# Print one reachability verdict per running instance tagged Project=USMS.
# The verdict is computed from the subnet's route table, the instance's public
# address and its security groups - never from names or tags.
# Read-only; safe to run at any time, from any directory.
#
# No `set -e`: every lookup below may legitimately return nothing (an instance
# with no public address, a subnet with no explicit route-table association),
# and one odd instance must not abort the report for all the others.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

# The route table a subnet uses: its explicit association, else the VPC's main table.
route_table_for() {
  local subnet=$1 vpc=$2 rt
  rt=$(aws ec2 describe-route-tables \
         --filters "Name=association.subnet-id,Values=$subnet" \
         --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  if [ -z "$rt" ] || [ "$rt" = "None" ]; then
    rt=$(aws ec2 describe-route-tables \
           --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
           --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  fi
  echo "${rt:-None}"
}

# The internet gateway the table's default route targets, or None.
igw_route() {
  aws ec2 describe-route-tables --route-table-ids "$1" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && starts_with(GatewayId || '', 'igw-')].GatewayId | [0]" \
    --output text 2>/dev/null || echo None
}

# "yes" if any of the given groups admits tcp/80 from 0.0.0.0/0.
sg_allows_80() {
  local hits
  # shellcheck disable=SC2086
  hits=$(aws ec2 describe-security-groups --group-ids $1 \
    --query "SecurityGroups[].IpPermissions[?(IpProtocol=='-1') || (FromPort<=\`80\` && ToPort>=\`80\`)][].IpRanges[?CidrIp=='0.0.0.0/0'][].CidrIp" \
    --output text 2>/dev/null)
  [ -n "$hits" ] && [ "$hits" != "None" ] && echo yes || echo no
}

aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --query 'sort_by(Reservations[].Instances[], &InstanceId)[].[Tags[?Key==`Name`]|[0].Value, PrivateIpAddress, PublicIpAddress, SubnetId, VpcId, join(`" "`, SecurityGroups[].GroupId)]' \
  --output text |
while IFS=$'\t' read -r name priv pub subnet vpc sgs; do
  [ "$pub" = "None" ] && pub="-"
  rt=$(route_table_for "$subnet" "$vpc")
  igw=$(igw_route "$rt")

  if [ -z "$igw" ] || [ "$igw" = "None" ]; then
    verdict=UNREACHABLE; why="no igw route on subnet"
  elif [ "$pub" = "-" ]; then
    verdict=NO-ADDRESS;  why="igw route present but no public address"
  elif [ "$(sg_allows_80 "$sgs")" = no ]; then
    verdict=BLOCKED;     why="igw route + public address, but no sg rule for 80/tcp from 0.0.0.0/0"
  else
    verdict=REACHABLE;   why="igw route + sg allows 80/tcp from 0.0.0.0/0"
  fi

  printf '%-20s %-12s %-15s %-12s %s\n' "$name" "$priv" "$pub" "$verdict" "$why"
done
