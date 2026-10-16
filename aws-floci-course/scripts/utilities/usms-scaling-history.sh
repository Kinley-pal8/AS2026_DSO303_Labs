#!/usr/bin/env bash
# Export usms-enrolment-svc's complete scaling configuration and history as ONE JSON document:
# the scalable target (bounds, suspension), every policy, every scheduled action, every alarm
# involved (with state), and every scaling activity. Every identifier is discovered, none typed.
# Writes outputs/lab-06-scaling-history.json and prints its path and size. Read-only otherwise.
set -uo pipefail   # no -e: unsupported reads are recorded in the document, not fatal.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
OUT="$REPO_ROOT/outputs/lab-06-scaling-history.json"

python3 - "$OUT" <<'PY'
import datetime, json, subprocess, sys

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        return {"_unavailable": (r.stderr.strip().splitlines() or ["error"])[-1]}
    return json.loads(r.stdout) if r.stdout.strip() else {}

# The resource ID is derived from the service ARN, exactly as Lab 06 Step 5 does.
clusters = aws("ecs", "list-clusters").get("clusterArns", [])
cluster = next(c.split("/")[-1] for c in clusters if c.split("/")[-1].startswith("usms-"))
svc_arn = next(a for a in aws("ecs", "list-services", "--cluster", cluster).get("serviceArns", [])
               if "enrolment" in a)
rid = svc_arn.split(":")[-1]

targets = aws("application-autoscaling", "describe-scalable-targets", "--service-namespace", "ecs", "--resource-ids", rid)
policies = aws("application-autoscaling", "describe-scaling-policies", "--service-namespace", "ecs", "--resource-id", rid)
scheduled = aws("application-autoscaling", "describe-scheduled-actions", "--service-namespace", "ecs", "--resource-id", rid)
activities = aws("application-autoscaling", "describe-scaling-activities", "--service-namespace", "ecs",
                 "--resource-id", rid, "--include-not-scaled-activities")

# Every alarm involved: the managed ones each policy lists, plus any alarm whose actions name a policy ARN.
pols = policies.get("ScalingPolicies", [])
arns = {p["PolicyARN"] for p in pols}
all_alarms = aws("cloudwatch", "describe-alarms").get("MetricAlarms", [])
listed = {a["AlarmName"] for p in pols for a in p.get("Alarms", [])}
alarms = [a for a in all_alarms if a["AlarmName"] in listed or arns & set(a.get("AlarmActions", []))]

doc = {
    "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "resourceId": rid,
    "serviceArn": svc_arn,
    "scalableTarget": (targets.get("ScalableTargets") or [None])[0],
    "scalingPolicies": pols,
    "scheduledActions": scheduled.get("ScheduledActions", scheduled),
    "alarms": alarms,
    "scalingActivities": activities.get("ScalingActivities", activities),
}
json.dump(doc, open(sys.argv[1], "w"), indent=2, default=str)
PY

python3 -m json.tool "$OUT" > /dev/null || { echo "invalid JSON: $OUT" >&2; exit 1; }
echo "$OUT $(wc -c < "$OUT") bytes"
