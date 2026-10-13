#!/usr/bin/env bash
# Print the decision table of every Application Load Balancer whose name starts with usms-:
# load balancer -> listeners -> rules in evaluation order -> target group health.
# Also writes outputs/lab-05-lb-report.json. Read-only; runs from any directory; no arguments.
#
# No `set -e`: a load balancer with no listeners, a listener with only its default rule and an
# empty target group are all legitimate, and one odd object must not abort the whole report.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

# Bash finds the paths and environment; Python does the four-level walk, because sorting rules
# by a string Priority and formatting nested actions is clearer there than in JMESPath and sed.
python3 - "$REPO_ROOT/outputs/lab-05-lb-report.json" <<'PY'
import json, subprocess, sys

def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else {}

def tg_summary(arn, names):
    desc = aws("elbv2", "describe-target-health", "--target-group-arn", arn).get("TargetHealthDescriptions", [])
    healthy = sum(1 for d in desc if d.get("TargetHealth", {}).get("State") == "healthy")
    return f"{names.get(arn, arn.split('/')[-2])}  ({len(desc)} targets, {healthy} healthy)", len(desc), healthy

def action_summary(action, names):
    t = action.get("Type", "?")
    if t == "forward":
        arn = action.get("TargetGroupArn") or (action.get("ForwardConfig", {}).get("TargetGroups") or [{}])[0].get("TargetGroupArn", "")
        return tg_summary(arn, names)[0] if arn else "forward (no target group)"
    if t == "fixed-response":
        return f"fixed-response {action.get('FixedResponseConfig', {}).get('StatusCode', '?')}"
    if t == "redirect":
        r = action.get("RedirectConfig", {})
        return f"redirect {r.get('StatusCode', '?')} -> {r.get('Protocol', '#{protocol}')}:{r.get('Port', '#{port}')}{r.get('Path', '')}"
    return t

def conditions(rule):
    if rule.get("IsDefault"):
        return "-", "-"
    c = (rule.get("Conditions") or [{}])[0]
    vals = c.get("Values") or c.get("PathPatternConfig", {}).get("Values") or c.get("HostHeaderConfig", {}).get("Values") or []
    return c.get("Field", "?"), ",".join(vals) or "-"

def prio_key(rule):
    # Priority is a STRING ("10", "20", "default"): sort numerically so "5" precedes "10",
    # and put the default action last because it is evaluated only when no rule matched.
    p = rule.get("Priority", "default")
    return (1, 0) if p == "default" else (0, int(p))

names = {tg["TargetGroupArn"]: tg["TargetGroupName"] for tg in aws("elbv2", "describe-target-groups").get("TargetGroups", [])}
lbs = [lb for lb in aws("elbv2", "describe-load-balancers").get("LoadBalancers", [])
       if lb.get("LoadBalancerName", "").startswith("usms-") and lb.get("Type") == "application"]

report = []
for lb in sorted(lbs, key=lambda x: x["LoadBalancerName"]):
    print(f"{lb['LoadBalancerName']:<20} {lb.get('Scheme','?'):<16} {lb.get('Type','?'):<12} "
          f"{lb.get('State',{}).get('Code','?'):<7} AZs={len(lb.get('AvailabilityZones',[]))}  SGs={len(lb.get('SecurityGroups',[]))}")
    entry = {"name": lb["LoadBalancerName"], "scheme": lb.get("Scheme"), "state": lb.get("State", {}).get("Code"), "listeners": []}
    listeners = aws("elbv2", "describe-listeners", "--load-balancer-arn", lb["LoadBalancerArn"]).get("Listeners", [])
    if not listeners:
        print("  (no listeners - this load balancer answers nothing)")
    for ln in sorted(listeners, key=lambda x: x.get("Port", 0)):
        print(f"  {ln.get('Protocol','?')}:{ln.get('Port','?')}")
        lentry = {"protocol": ln.get("Protocol"), "port": ln.get("Port"), "rules": []}
        rules = aws("elbv2", "describe-rules", "--listener-arn", ln["ListenerArn"]).get("Rules", [])
        for r in sorted(rules, key=prio_key):
            field, vals = conditions(r)
            act = action_summary((r.get("Actions") or [{}])[0], names)
            print(f"    prio  {r.get('Priority','?'):<8} {field:<13} {vals:<27} -> {act}")
            lentry["rules"].append({"priority": r.get("Priority"), "field": field, "values": vals, "action": act})
        entry["listeners"].append(lentry)
    report.append(entry)

if not lbs:
    print("(no application load balancers named usms-*)")
json.dump({"load_balancers": report}, open(sys.argv[1], "w"), indent=2)
PY
