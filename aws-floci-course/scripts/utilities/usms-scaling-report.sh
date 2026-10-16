#!/usr/bin/env bash
# Print the auto scaling decision table for every scalable target in the ecs namespace whose
# resource ID names a cluster beginning usms-, with a verdict COMPUTED from the target's own
# fields. Also writes outputs/lab-06-scaling-report.json. Read-only; no arguments; any directory.
#
# No `set -e`: on this course's emulator several reads are unimplemented (scheduled actions,
# scaling activities) and a target may legitimately have no policies; each of those must be
# reported as such, not abort the report.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

# Bash resolves paths and environment; Python does the discovery walk and the formatting,
# because every level is JSON and the verdict needs several fields compared at once.
python3 - "$REPO_ROOT/outputs/lab-06-scaling-report.json" <<'PY'
import json, subprocess, sys

def aws(*args):
    """Return (ok, parsed-json). ok is False when the call failed or is unsupported."""
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        return False, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "error"
    return True, json.loads(r.stdout) if r.stdout.strip() else {}

SHORT = {"ECSServiceAverageCPUUtilization": "CPU", "ECSServiceAverageMemoryUtilization": "Memory",
         "ALBRequestCountPerTarget": "ALBReq"}

def verdict(t, desired, n_policies):
    # Top to bottom, first match wins. PINNED first: with min == max nothing can move, so every
    # other state is irrelevant. FROZEN outranks AT-CEILING / AT-FLOOR because a suspended target
    # will not move even when the metric says it should, so "at the ceiling" would wrongly suggest
    # the policies are working and simply out of room. The two AT-* verdicts describe a live,
    # elastic target that is pressed against a bound; ELASTIC is what remains.
    s = t.get("SuspendedState", {}) or {}
    if t["MinCapacity"] == t["MaxCapacity"]:
        return "PINNED"
    if any(s.get(k) for k in ("DynamicScalingInSuspended", "DynamicScalingOutSuspended", "ScheduledScalingSuspended")):
        return "FROZEN"
    if desired is not None and desired == t["MaxCapacity"]:
        return "AT-CEILING"
    if desired is not None and desired == t["MinCapacity"] and n_policies > 1:
        return "AT-FLOOR"
    return "ELASTIC"

ok, targets = aws("application-autoscaling", "describe-scalable-targets", "--service-namespace", "ecs")
targets = [t for t in (targets.get("ScalableTargets", []) if ok else [])
           if t["ResourceId"].split("/")[1:2] and t["ResourceId"].split("/")[1].startswith("usms-")]
report = []
if not targets:
    print("(no scalable targets in the ecs namespace for a usms- cluster)")

for t in sorted(targets, key=lambda x: x["ResourceId"]):
    rid = t["ResourceId"]
    _, cluster, service = rid.split("/")
    ok, svc = aws("ecs", "describe-services", "--cluster", cluster, "--services", service)
    s0 = (svc.get("services") or [{}])[0] if ok else {}
    desired, running = s0.get("desiredCount"), s0.get("runningCount")

    ok, pol = aws("application-autoscaling", "describe-scaling-policies", "--service-namespace", "ecs", "--resource-id", rid)
    policies = sorted(pol.get("ScalingPolicies", []) if ok else [], key=lambda p: p["PolicyName"])
    v = verdict(t, desired, len(policies))

    print(f"{rid}   {t['ScalableDimension']}")
    print(f"  {'bounds':<13} min={t['MinCapacity']} max={t['MaxCapacity']}  desired={desired} running={running}".ljust(76) + v)
    susp = [k.replace("Suspended", "") for k, val in (t.get("SuspendedState") or {}).items() if val]
    print(f"  {'suspended':<13} {', '.join(susp) if susp else 'none'}")

    # Batch every alarm name the policies mention (managed and custom) into one describe-alarms call.
    custom = []
    ok_a, al_all = aws("cloudwatch", "describe-alarms")
    alarms = al_all.get("MetricAlarms", []) if ok_a else []
    state = {a["AlarmName"]: a for a in alarms}
    entry = {"resourceId": rid, "min": t["MinCapacity"], "max": t["MaxCapacity"], "desired": desired,
             "running": running, "verdict": v, "suspended": susp, "policies": [], "scheduled": [], "lastActivity": None}

    if not policies:
        print(f"  {'policies':<13} none")
    for p in policies:
        if p["PolicyType"] == "TargetTrackingScaling":
            c = p["TargetTrackingScalingPolicyConfiguration"]
            m = SHORT.get(c.get("PredefinedMetricSpecification", {}).get("PredefinedMetricType", ""), "custom")
            flag = "  (scale-out only)" if c.get("DisableScaleIn") else ""
            mt = f"{m}/{c['TargetValue']}"
            print(f"  {'target-track':<13} {p['PolicyName']:<40} {mt:<14} out={c.get('ScaleOutCooldown')} in={c.get('ScaleInCooldown')}{flag}")
            names = [a["AlarmName"] for a in p.get("Alarms", [])]
            if names:
                parts = []
                for n in names:
                    kind = "AlarmHigh" if "AlarmHigh" in n else "AlarmLow" if "AlarmLow" in n else n
                    parts.append(f"{kind}={state.get(n, {}).get('StateValue', 'MISSING')}")
                print(f"  {'':<13} alarms {' '.join(parts)}")
            else:
                print(f"  {'':<13} alarms none listed on the policy")
            entry["policies"].append({"name": p["PolicyName"], "type": "target-tracking", "metric": m, "target": c["TargetValue"]})
        else:
            c = p["StepScalingPolicyConfiguration"]
            steps = " / ".join(f"{s['ScalingAdjustment']:+d}" for s in c.get("StepAdjustments", []))
            print(f"  {'step':<13} {p['PolicyName']:<40} {steps:<14} cooldown={c.get('Cooldown')}")
            # A step policy's alarm is found from the alarm side: whichever alarm names this policy ARN.
            mine = [a for a in alarms if p["PolicyARN"] in a.get("AlarmActions", [])]
            for a in mine:
                op = {"GreaterThanOrEqualToThreshold": ">=", "GreaterThanThreshold": ">",
                      "LessThanThreshold": "<", "LessThanOrEqualToThreshold": "<="}.get(a["ComparisonOperator"], a["ComparisonOperator"])
                print(f"  {'':<13} alarm {a['AlarmName']} = {a['StateValue']}  ({a['Namespace']} {a['MetricName']} {op} {a['Threshold']:g})")
            if not mine:
                print(f"  {'':<13} alarm none invokes this policy")
            entry["policies"].append({"name": p["PolicyName"], "type": "step", "steps": steps})

    ok, sch = aws("application-autoscaling", "describe-scheduled-actions", "--service-namespace", "ecs", "--resource-id", rid)
    if not ok:
        print(f"  {'scheduled':<13} not readable on this build ({sch.split(':')[-1].strip()})")
    elif not sch.get("ScheduledActions"):
        print(f"  {'scheduled':<13} none")
    else:
        for a in sorted(sch["ScheduledActions"], key=lambda x: x["ScheduledActionName"]):
            print(f"  {'scheduled':<13} {a['ScheduledActionName']:<34} {a['Schedule']:<26} {a.get('Timezone','UTC'):<13} min={a.get('ScalableTargetAction',{}).get('MinCapacity')}")
            entry["scheduled"].append(a["ScheduledActionName"])

    ok, act = aws("application-autoscaling", "describe-scaling-activities", "--service-namespace", "ecs", "--resource-id", rid, "--max-items", "1")
    if not ok:
        print(f"  {'last activity':<13} not readable on this build")
    elif not act.get("ScalingActivities"):
        print(f"  {'last activity':<13} none recorded")
    else:
        a = act["ScalingActivities"][0]
        entry["lastActivity"] = a.get("Description")
        print(f"  {'last activity':<13} {a.get('StartTime','')}  {a.get('StatusCode','')}  {a.get('Description','')}")
    report.append(entry)

json.dump({"targets": report}, open(sys.argv[1], "w"), indent=2, default=str)
PY
