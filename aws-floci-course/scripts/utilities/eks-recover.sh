#!/usr/bin/env bash
# Bring usms-eks-cluster back after a Floci restart or a machine reboot.
# Two cases, seen in Lab 07:
#   a) the k3s container still exists but is stopped (reboot, Docker restart): its data is intact.
#      Restart it so it gets its old bridge IP back, and point its token webhook at Floci by NAME
#      (Floci's IP changes across reboots). Nothing is recreated.
#   b) the k3s container is gone (floci-down.sh removes it, Step 22): every Kubernetes object is
#      gone with it. Rebuild from committed files:
#   1. recreate the node group and cluster from templates/lab-07-create-*.json (as usms-developer-role)
#   2. point kubectl at it again (context usms-eks, namespace usms)
#   3. re-register the IAM OIDC provider for the new issuer, deleting the stale one
#   4. kubectl apply -f manifests/lab-07/  - the whole application, declaratively
#   5. join the worker nodes (eks-nodes-join.sh) and make sure the LB port forwarder runs
#   6. smoke test through the gateway
# Does nothing to a healthy cluster. --force skips case a) and recreates.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
for f in course lab-07; do source "$REPO_ROOT/configs/$f.env"; done

SERVER=floci-floci-course-eks-${USMS_EKS_CLUSTER}

if [ "${1:-}" != --force ] && docker container inspect "$SERVER" >/dev/null 2>&1 \
   && kubectl --context usms-eks get namespace "$USMS_EKS_NAMESPACE" --request-timeout=5s >/dev/null 2>&1; then
  echo "cluster is healthy (k3s container present, namespace $USMS_EKS_NAMESPACE exists) - nothing to do"
  exit 0
fi

# Point the API server's token webhook at Floci by container name instead of the IP it had when
# the cluster was created; without this, kubectl gets "provide credentials" after a reboot.
fix_webhook() {
  docker exec "$SERVER" grep -q 'http://floci\.:4566' /etc/token-webhook.yaml && return 0
  docker exec "$SERVER" sed -i 's|http://[0-9.]*:4566|http://floci.:4566|' /etc/token-webhook.yaml
  docker restart "$SERVER" >/dev/null && echo "token webhook now http://floci.:4566 (k3s restarted)"
}

if docker container inspect "$SERVER" >/dev/null 2>&1 && [ "${1:-}" != --force ]; then
  echo "== a. k3s container exists - restarting it in place (data kept)"
  # Docker hands out the lowest free bridge address, so the ECR registry must not take the IP k3s
  # recorded as its node IP: restart the registry first, then k3s.
  REG=floci-floci-course-ecr-registry
  docker container inspect "$REG" >/dev/null 2>&1 && { docker stop "$REG" >/dev/null; docker start "$REG" >/dev/null; }
  docker stop "$SERVER" >/dev/null 2>&1; docker start "$SERVER" >/dev/null
  fix_webhook
  timeout 180 sh -c 'until kubectl --context usms-eks get nodes --request-timeout=5s >/dev/null 2>&1; do sleep 3; done' \
    || { echo "API server did not come back - rerun with --force to recreate" >&2; exit 1; }
  kubectl config use-context usms-eks >/dev/null
  kubectl get nodes
  "$REPO_ROOT/scripts/utilities/eks-nodes-join.sh" || echo "WARNING: worker nodes did not join" >&2
  for d in $(kubectl get deploy -n "$USMS_EKS_NAMESPACE" -o name); do
    kubectl rollout status "$d" -n "$USMS_EKS_NAMESPACE" --timeout=180s
  done
  docker start usms-eks-lbfwd >/dev/null 2>&1 && echo "usms-eks-lbfwd running (127.0.0.1:8081-8082)"
  kubectl run usms-smoke --rm -i --restart=Never --image=busybox:1.36 -n "$USMS_EKS_NAMESPACE" -- sh -c '
    G=http://usms-gateway.usms.svc.cluster.local
    wget -qO- $G/ && wget -qO- $G/enrolment/ && wget -qO- $G/results/
  ' && echo "SMOKE TEST PASSED"
  exit 0
fi

echo "== b. k3s container is gone - recreating"
docker rm -f "$SERVER" >/dev/null 2>&1
echo "== 1. recreate the cluster and node group from the committed request bodies"
aws eks delete-nodegroup --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" >/dev/null 2>&1 \
  && aws eks wait nodegroup-deleted --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP"
aws eks delete-cluster --name "$USMS_EKS_CLUSTER" >/dev/null 2>&1 \
  && aws eks wait cluster-deleted --name "$USMS_EKS_CLUSTER"
( CREDS=$(aws sts assume-role --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/usms-developer-role" \
    --role-session-name lab07-eks-recover --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
  export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | cut -f1) AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | cut -f2) \
         AWS_SESSION_TOKEN=$(echo "$CREDS" | cut -f3)
  aws eks create-cluster --cli-input-json file://templates/lab-07-create-cluster.json \
    --query 'cluster.[name,status]' --output text )    # subshell: the assumed credentials die with it
aws eks wait cluster-active --name "$USMS_EKS_CLUSTER" || { echo "cluster did not become ACTIVE" >&2; exit 1; }
aws eks create-nodegroup --cli-input-json file://templates/lab-07-create-nodegroup.json \
  --query 'nodegroup.[nodegroupName,status]' --output text
aws eks wait nodegroup-active --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP"

fix_webhook
echo "== 2. kubectl context"
aws eks update-kubeconfig --name "$USMS_EKS_CLUSTER" --alias usms-eks >/dev/null
kubectl config use-context usms-eks >/dev/null
kubectl config set-context --current --namespace="$USMS_EKS_NAMESPACE" >/dev/null
timeout 120 sh -c 'until kubectl get nodes --request-timeout=5s >/dev/null 2>&1; do sleep 2; done'
kubectl cluster-info | head -1

echo "== 3. OIDC provider for the new issuer"
ISSUER=$(aws eks describe-cluster --name "$USMS_EKS_CLUSTER" --query 'cluster.identity.oidc.issuer' --output text)
for A in $(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text); do
  case "$A" in
    *"${ISSUER##*/}") ;;
    *oidc-provider/oidc.eks.*) aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$A" && echo "deleted stale $A" ;;
  esac
done
aws iam create-open-id-connect-provider --url "$ISSUER" --client-id-list sts.amazonaws.com \
  --thumbprint-list 9e99a48a9960b14926bb7f3b02e22da2b0ab7280 --query 'OpenIDConnectProviderArn' --output text 2>/dev/null \
  || echo "provider for $ISSUER already registered"

echo "== 4. the application, from the manifests"
kubectl apply -f "$USMS_K8S_MANIFEST_DIR/"
for d in $(kubectl get deploy -n "$USMS_EKS_NAMESPACE" -o name); do
  kubectl rollout status "$d" -n "$USMS_EKS_NAMESPACE" --timeout=180s
done

echo "== 5. worker nodes and LB host ports"
"$REPO_ROOT/scripts/utilities/eks-nodes-join.sh" || echo "WARNING: worker nodes did not join; the app still runs on the server node" >&2
if docker container inspect usms-eks-lbfwd >/dev/null 2>&1; then
  docker start usms-eks-lbfwd >/dev/null && echo "usms-eks-lbfwd running (127.0.0.1:8081-8082)"
else
  echo "usms-eks-lbfwd is missing - LoadBalancer Services are reachable only at the node IP (see notes/lab-07-notes.md)"
fi

echo "== 6. smoke test"
kubectl run usms-smoke --rm -i --restart=Never --image=busybox:1.36 -n "$USMS_EKS_NAMESPACE" -- sh -c '
  G=http://usms-gateway.usms.svc.cluster.local
  wget -qO- $G/ && wget -qO- $G/enrolment/ && wget -qO- $G/results/
' && echo "SMOKE TEST PASSED"
