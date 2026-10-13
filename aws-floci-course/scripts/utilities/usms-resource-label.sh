#!/usr/bin/env bash
# Print the ResourceLabel that Application Auto Scaling's ALBRequestCountPerTarget metric needs:
#   app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>
# Derived from the API, never from configs/lab-05.env or a typed identifier.
# Usage: usms-resource-label.sh [load-balancer-name] [target-group-name]
set -euo pipefail   # -e is right here: any failed lookup means there is no label to print.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
           --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
           --query 'TargetGroups[0].TargetGroupArn' --output text)

# The two suffixes are cut differently. The load balancer part must DROP its resource type
# ("loadbalancer/"), so strip everything up to and including ":loadbalancer/". The target
# group part must KEEP its resource type ("targetgroup/..."), which is simply everything
# after the ARN's last colon.
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"   # app/usms-enrolment-alb/<id>
TG_SUFFIX="${TG_ARN##*:}"               # targetgroup/usms-enrolment-tg/<id>
LABEL="$LB_SUFFIX/$TG_SUFFIX"

# Plausibility: six slash-separated segments, "app" first, "targetgroup" fourth, both names present.
IFS=/ read -r s1 s2 s3 s4 s5 s6 extra <<< "$LABEL"
if [ "$s1" != app ] || [ "$s2" != "$LB_NAME" ] || [ -z "$s3" ] || [ "$s4" != targetgroup ] \
   || [ "$s5" != "$TG_NAME" ] || [ -z "$s6" ] || [ -n "${extra:-}" ]; then
  echo "error: implausible ResourceLabel '$LABEL'" >&2
  exit 1
fi

echo "$LABEL"
