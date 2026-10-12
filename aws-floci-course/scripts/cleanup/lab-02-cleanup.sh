#!/usr/bin/env bash
# END OF COURSE ONLY. Tears down the Lab 02 network, dependencies first.
# Run scripts/cleanup/lab-03-cleanup.sh FIRST - a VPC with instances in it
# cannot be deleted.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

cat <<'WARN'
============================================================
  This DELETES usms-vpc and everything in it: subnets, route
  tables, security groups, NACL, NAT gateway, its Elastic IP,
  the internet gateway and the S3 endpoint. Not reversible.
  Run lab-03-cleanup.sh BEFORE this script.
============================================================
WARN

read -r -p 'Type exactly: DELETE USMS NETWORK  > ' answer
[ "$answer" = "DELETE USMS NETWORK" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "delete the S3 endpoint"
aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$USMS_S3_ENDPOINT" || true

say "delete the NAT gateway, then release its Elastic IP"
aws ec2 delete-nat-gateway --nat-gateway-id "$USMS_NAT_GW" || true
aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$USMS_NAT_GW" 2>/dev/null || sleep 10
aws ec2 release-address --allocation-id "$USMS_NAT_EIP_ALLOC" || true

say "delete security groups (db first: it references app)"
aws ec2 delete-security-group --group-id "$USMS_DB_SG" || true
aws ec2 delete-security-group --group-id "$USMS_APP_SG" || true

say "delete subnets (this drops their route-table and NACL associations)"
for s in "$USMS_PUBLIC_SUBNET_A" "$USMS_PUBLIC_SUBNET_B" "$USMS_PRIVATE_SUBNET_A" "$USMS_PRIVATE_SUBNET_B"; do
  [ "$s" != "None" ] && aws ec2 delete-subnet --subnet-id "$s" || true
done

say "delete route tables and the private NACL"
aws ec2 delete-route-table --route-table-id "$USMS_PUBLIC_RT" || true
aws ec2 delete-route-table --route-table-id "$USMS_PRIVATE_RT" || true
aws ec2 delete-network-acl --network-acl-id "$USMS_PRIVATE_NACL" || true

say "detach and delete the internet gateway"
aws ec2 detach-internet-gateway --internet-gateway-id "$USMS_IGW_ID" --vpc-id "$USMS_VPC_ID" || true
aws ec2 delete-internet-gateway --internet-gateway-id "$USMS_IGW_ID" || true

say "delete the VPC"
aws ec2 delete-vpc --vpc-id "$USMS_VPC_ID" || true

echo; echo "Lab 02 teardown complete."
