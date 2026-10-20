#!/usr/bin/env bash
# END OF COURSE ONLY. Deletes every Lab 07 resource, dependencies inside-out.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

cat <<'WARN'
This deletes:
  - Kubernetes namespace usms and everything inside it
  - EKS node group usms-eks-nodes
  - EKS cluster usms-eks-cluster
  - IAM roles usms-eks-cluster-role and usms-eks-node-role
  - IAM policies USMSEKSClusterPolicy and USMSEKSNodePolicy
  - Security group usms-eks-cluster-sg
  - The IAM OIDC provider registered for the cluster's issuer (Step 21)
  - Local containers usms-eks-node-* (eks-nodes-join.sh) and usms-eks-lbfwd (LB host ports)
It does NOT delete USMSStudentDataReadWrite, which Lab 03 and Lab 04 still use.
WARN

printf 'Type exactly DELETE-LAB-07 to proceed: '
read -r CONFIRM
[ "$CONFIRM" = "DELETE-LAB-07" ] || { echo "aborted"; exit 1; }

# 0. Read the cluster's OIDC issuer now: once the cluster is gone, nothing names it.
OIDC_HOST=$(aws eks describe-cluster --name usms-eks-cluster \
  --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null | sed 's|^https://||')

# 1. Kubernetes objects first: the cluster cannot be deleted while a
#    LoadBalancer Service still holds a load balancer (Lab 08 creates one).
kubectl delete namespace usms --ignore-not-found --timeout=180s

# 1b. The local worker nodes and the LB port forwarder (not AWS objects, so no API removes them).
docker rm -f $(docker ps -aq --filter name=usms-eks-node- --filter label=lab=07) usms-eks-lbfwd 2>/dev/null

# 2. Node group before cluster. A cluster with a node group refuses to delete.
aws eks delete-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null
aws eks wait nodegroup-deleted --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null || sleep 30

# 3. Cluster.
aws eks delete-cluster --name usms-eks-cluster 2>/dev/null
aws eks wait cluster-deleted --name usms-eks-cluster 2>/dev/null || sleep 30

# 4. Detach before delete. delete-role fails with DeleteConflict while a
#    managed policy is attached, and the error does not name the policy.
for R in usms-eks-cluster-role usms-eks-node-role; do
  for P in $(aws iam list-attached-role-policies --role-name "$R" \
               --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$R" --policy-arn "$P"
  done
  aws iam delete-role --role-name "$R" 2>/dev/null
done

# 5. Our own policies only. Never USMSStudentDataReadWrite.
for N in USMSEKSClusterPolicy USMSEKSNodePolicy; do
  A=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$N'].Arn | [0]" --output text 2>/dev/null)
  [ -n "$A" ] && [ "$A" != "None" ] && aws iam delete-policy --policy-arn "$A"
done

# 5b. The OIDC provider Step 21 registered (its ARN ends in the issuer's host and path).
if [ -n "$OIDC_HOST" ] && [ "$OIDC_HOST" != "None" ]; then
  aws iam delete-open-id-connect-provider \
    --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}" 2>/dev/null
fi

# 6. Security group last: it cannot be deleted while an interface uses it.
SG=$(aws ec2 describe-security-groups --filters Name=group-name,Values=usms-eks-cluster-sg \
       --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG"

echo "Lab 07 resources removed."
