#!/usr/bin/env bash
# Verify every Lab 02 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Read-only; safe to run at any time.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

: "${USMS_VPC_ID:=none}"
: "${USMS_IGW_ID:=none}"
: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PUBLIC_SUBNET_B:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_PUBLIC_RT:=none}"
: "${USMS_PRIVATE_RT:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_DB_SG:=none}"
: "${USMS_PRIVATE_NACL:=none}"
: "${USMS_NAT_GW:=none}"
: "${USMS_NAT_EIP_ALLOC:=none}"
: "${USMS_S3_ENDPOINT:=none}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# Helpers: one subnet field, and the default-route target of a route table.
sn() { aws ec2 describe-subnets --subnet-ids "$1" --query "Subnets[0].$2" --output text; }
rt_default() { aws ec2 describe-route-tables --route-table-ids "$1" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[GatewayId,NatGatewayId]" --output text; }
rt_of() { aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=$1" \
  --query 'RouteTables[0].RouteTableId' --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== VPC =="
check "usms-vpc exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "usms-vpc CIDR is 10.0.0.0/16" \
  "test \"\$(aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID --query 'Vpcs[0].CidrBlock' --output text)\" = 10.0.0.0/16"
check "DNS hostnames enabled" \
  "test \"\$(aws ec2 describe-vpc-attribute --vpc-id $USMS_VPC_ID --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text)\" = True"

echo "== Internet gateway =="
check "usms-igw exists" "aws ec2 describe-internet-gateways --internet-gateway-ids $USMS_IGW_ID"
check "usms-igw ATTACHED to usms-vpc" \
  "test \"\$(aws ec2 describe-internet-gateways --internet-gateway-ids $USMS_IGW_ID --query 'InternetGateways[0].Attachments[0].VpcId' --output text)\" = $USMS_VPC_ID"

echo "== Subnets =="
check "usms-public-subnet-a is 10.0.1.0/24 in $USMS_AZ_A" \
  "test \"\$(sn $USMS_PUBLIC_SUBNET_A CidrBlock) \$(sn $USMS_PUBLIC_SUBNET_A AvailabilityZone)\" = '10.0.1.0/24 $USMS_AZ_A'"
check "usms-public-subnet-b is 10.0.2.0/24 in $USMS_AZ_B" \
  "test \"\$(sn $USMS_PUBLIC_SUBNET_B CidrBlock) \$(sn $USMS_PUBLIC_SUBNET_B AvailabilityZone)\" = '10.0.2.0/24 $USMS_AZ_B'"
check "usms-private-subnet-a is 10.0.3.0/24 in $USMS_AZ_A" \
  "test \"\$(sn $USMS_PRIVATE_SUBNET_A CidrBlock) \$(sn $USMS_PRIVATE_SUBNET_A AvailabilityZone)\" = '10.0.3.0/24 $USMS_AZ_A'"
check "usms-private-subnet-b is 10.0.4.0/24 in $USMS_AZ_B" \
  "test \"\$(sn $USMS_PRIVATE_SUBNET_B CidrBlock) \$(sn $USMS_PRIVATE_SUBNET_B AvailabilityZone)\" = '10.0.4.0/24 $USMS_AZ_B'"
check "public-subnet-a auto-assigns public IPs" "test \"\$(sn $USMS_PUBLIC_SUBNET_A MapPublicIpOnLaunch)\" = True"
check "public-subnet-b auto-assigns public IPs" "test \"\$(sn $USMS_PUBLIC_SUBNET_B MapPublicIpOnLaunch)\" = True"
check "private-subnet-a does NOT auto-assign"   "test \"\$(sn $USMS_PRIVATE_SUBNET_A MapPublicIpOnLaunch)\" = False"
check "private-subnet-b does NOT auto-assign"   "test \"\$(sn $USMS_PRIVATE_SUBNET_B MapPublicIpOnLaunch)\" = False"

echo "== Routing =="
check "usms-public-rt 0.0.0.0/0 -> usms-igw" "rt_default $USMS_PUBLIC_RT | grep -q $USMS_IGW_ID"
check "usms-private-rt 0.0.0.0/0 -> usms-nat" "rt_default $USMS_PRIVATE_RT | grep -q $USMS_NAT_GW"
check "usms-private-rt has NO route to any igw" \
  "! aws ec2 describe-route-tables --route-table-ids $USMS_PRIVATE_RT --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q igw-"
check "public-subnet-a uses usms-public-rt"   "test \"\$(rt_of $USMS_PUBLIC_SUBNET_A)\" = $USMS_PUBLIC_RT"
check "public-subnet-b uses usms-public-rt"   "test \"\$(rt_of $USMS_PUBLIC_SUBNET_B)\" = $USMS_PUBLIC_RT"
check "private-subnet-a uses usms-private-rt" "test \"\$(rt_of $USMS_PRIVATE_SUBNET_A)\" = $USMS_PRIVATE_RT"
check "private-subnet-b uses usms-private-rt" "test \"\$(rt_of $USMS_PRIVATE_SUBNET_B)\" = $USMS_PRIVATE_RT"

echo "== Security groups =="
check "usms-app-sg exists" "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "usms-app-sg admits tcp/80 from 0.0.0.0/0" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_APP_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[0].CidrIp | [0]' --output text)\" = 0.0.0.0/0"
check "usms-db-sg exists" "aws ec2 describe-security-groups --group-ids $USMS_DB_SG"
check "usms-db-sg admits 5432 from usms-app-sg (group reference)" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_DB_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`5432\`].UserIdGroupPairs[0].GroupId | [0]' --output text)\" = $USMS_APP_SG"
check "usms-db-sg has NO CIDR-based ingress" \
  "test -z \"\$(aws ec2 describe-security-groups --group-ids $USMS_DB_SG --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text)\""

echo "== Network ACL =="
check "usms-private-nacl exists" "aws ec2 describe-network-acls --network-acl-ids $USMS_PRIVATE_NACL"
check "usms-private-nacl associated with private-subnet-a" \
  "aws ec2 describe-network-acls --network-acl-ids $USMS_PRIVATE_NACL --query 'NetworkAcls[0].Associations[].SubnetId' --output text | grep -q $USMS_PRIVATE_SUBNET_A"

echo "== NAT gateway and S3 endpoint =="
check "usms-nat is available" \
  "test \"\$(aws ec2 describe-nat-gateways --nat-gateway-ids $USMS_NAT_GW --query 'NatGateways[0].State' --output text)\" = available"
check "usms-nat sits in a public subnet" \
  "test \"\$(aws ec2 describe-nat-gateways --nat-gateway-ids $USMS_NAT_GW --query 'NatGateways[0].SubnetId' --output text)\" = $USMS_PUBLIC_SUBNET_A"
check "usms-nat-eip allocated" "aws ec2 describe-addresses --allocation-ids $USMS_NAT_EIP_ALLOC"
check "usms-s3-endpoint attached to usms-private-rt" \
  "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $USMS_S3_ENDPOINT --query 'VpcEndpoints[0].RouteTableIds' --output text | grep -q $USMS_PRIVATE_RT"

echo "== Files =="
check "configs/lab-02.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-02.env"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
