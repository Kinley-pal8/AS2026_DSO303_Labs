#!/usr/bin/env bash
# Give usms-eks-cluster the worker nodes its node group describes.
# Floci 1.7 records usms-eks-nodes but provisions no node: the cluster is one k3s server.
# This joins <desiredSize> k3s agent containers to that server, labelled as EKS labels
# a managed node group's nodes. Re-runnable: existing agents are replaced (a recreated
# cluster has a new join token). Local emulation only - real EKS launches EC2 instances.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-07.env"

SERVER=floci-floci-course-eks-${USMS_EKS_CLUSTER}
IMAGE=rancher/k3s:v1.34.1-k3s1        # same version as the server Floci starts

[ "$(docker container inspect "$SERVER" --format '{{.State.Running}}' 2>/dev/null)" = true ] \
  || { echo "k3s server container $SERVER is not running - run eks-recover.sh first" >&2; exit 1; }

# Desired size and labels come from the node group record, not from this script.
DESIRED=$(aws eks describe-nodegroup --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --query 'nodegroup.scalingConfig.desiredSize' --output text)
LABELS=$(aws eks describe-nodegroup --cluster-name "$USMS_EKS_CLUSTER" --nodegroup-name "$USMS_EKS_NODEGROUP" \
  --query 'nodegroup.labels' --output json | python3 -c 'import json,sys; print(" ".join(f"--node-label={k}={v}" for k,v in json.load(sys.stdin).items()))')

# The server's address on Docker's default bridge is the node address k3s advertises (its INTERNAL-IP).
SERVER_IP=$(docker inspect "$SERVER" --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
TOKEN=$(docker exec "$SERVER" cat /var/lib/rancher/k3s/server/node-token)

echo "server $SERVER at $SERVER_IP, node group desiredSize=$DESIRED, labels: $LABELS"
for n in $(seq 1 "$DESIRED"); do
  NAME=usms-eks-node-$n
  docker rm -f "$NAME" >/dev/null 2>&1
  # A rejoining agent has a new node password; k3s rejects it ("hash does not match") while the
  # old Node object and its password secret remain, so remove both first.
  kubectl delete node "$NAME" --ignore-not-found >/dev/null
  kubectl -n kube-system delete secret "$NAME.node-password.k3s" --ignore-not-found >/dev/null
  docker run -d --name "$NAME" --hostname "$NAME" --privileged --restart unless-stopped \
    --tmpfs /run --tmpfs /var/run --label project=usms --label lab=07 \
    -e K3S_URL="https://$SERVER_IP:6443" -e K3S_TOKEN="$TOKEN" \
    "$IMAGE" agent --node-name "$NAME" $LABELS \
    --node-label "eks.amazonaws.com/nodegroup=$USMS_EKS_NODEGROUP" >/dev/null && echo "started $NAME"
done

# Wait for every agent to register and turn Ready.
for n in $(seq 1 "$DESIRED"); do
  timeout 120 sh -c "until kubectl get node usms-eks-node-$n --no-headers 2>/dev/null | grep -qw Ready; do sleep 3; done" \
    || echo "usms-eks-node-$n did not become Ready" >&2
done
# Copy the course images from the server node's cache (Troubleshooting 6). A fresh agent pulling
# nginx from Docker Hub can stall for many minutes, leaving rollouts stuck in ContainerCreating.
for img in docker.io/library/nginx:1.27-alpine docker.io/library/busybox:1.36; do
  for n in $(seq 1 "$DESIRED"); do
    docker exec "$SERVER" ctr -n k8s.io images export --platform linux/amd64 - "$img" 2>/dev/null \
      | docker exec -i "usms-eks-node-$n" ctr -n k8s.io images import --platform linux/amd64 - >/dev/null 2>&1 \
      && echo "preloaded $img on usms-eks-node-$n"
  done
done

kubectl get nodes -L workload,tier,eks.amazonaws.com/nodegroup
