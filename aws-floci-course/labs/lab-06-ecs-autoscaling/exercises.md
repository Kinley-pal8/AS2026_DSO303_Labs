# Lab 06 - Independent Exercises

All commands were run from `aws-floci-course/` against Floci 1.7.0 (support path **B**, control plane only). Captured output is in `outputs/lab-06-ex*.txt` (git-ignored).

---

## Exercise 1 - Basic: a memory policy, and a scale-out-only policy

`templates/lab-06-target-tracking-memory.json` (quoted heredoc, no variables, zero `$`):

```json
{ "TargetValue": 70.0,
  "PredefinedMetricSpecification": { "PredefinedMetricType": "ECSServiceAverageMemoryUtilization" },
  "ScaleOutCooldown": 60, "ScaleInCooldown": 600, "DisableScaleIn": true }
```

```bash
MEM_ARN=$(aws application-autoscaling put-scaling-policy --service-namespace ecs --resource-id "$RID" \
  --scalable-dimension "$SDIM" --policy-name usms-enrolment-memory-target-tracking \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file://templates/lab-06-target-tracking-memory.json \
  --query 'PolicyARN' --output text)
```

```text
| Alarms | Metric                              | Name                                    | NoScaleIn | Target |
|  2     | ECSServiceAverageCPUUtilization     | usms-enrolment-cpu-target-tracking      | False     | 50.0   |
|  2     | ECSServiceAverageMemoryUtilization  | usms-enrolment-memory-target-tracking   | True      | 70.0   |
|  0     | None                                | usms-enrolment-queue-step-out           | None      | None   |
|  2     | ALBRequestCountPerTarget            | usms-enrolment-requests-target-tracking | False     | 1000.0 |
managed alarms before: 4    after: 6
bounds unchanged: 2 10      verify-lab-06: PASS=39 FAIL=3 (unchanged, as predicted)
```

**Prediction for Section 8:** unchanged. The script counts neither policies nor managed alarms precisely (it checks "2+"), so an extra policy cannot make it fail. The three failures remain the unsupported scheduled actions.

**Answers:**

- **Why five and not six?** On real AWS a `DisableScaleIn: true` policy gets only the **high** alarm, because the low alarm exists only to trigger scale-in, which this policy is forbidden to do, so its absence means memory can only ever push the service *up*. **On Floci the count went to six:** it created a pointless `AlarmLow` anyway, which is a recorded limitation.
- **Memory 70 against CPU 50: which scales out first?** Whichever metric crosses its target first, relative to how this workload uses resources. nginx-style request handling is usually CPU-bound before it is memory-bound, so CPU at 50 would normally fire first. To answer properly I would need both metrics measured under real load (Container Insights or a load test), because the targets are percentages of two different reservations (256 CPU units, 512 MiB).
- **Does a scale-out-only policy change the other two's scale-in?** It does not *remove* their scale-in, but it can only add capacity, never take it away. By Step 9's rule, scale-in needs every policy to agree. A `DisableScaleIn` policy has no low alarm on real AWS, so it never triggers a scale-in itself, and the documentation describes it as leaving scale-in to the other policies. In practice, while memory is above 70 it keeps asking for *more* capacity, which outweighs any scale-in the CPU or request policy wants (scale-out wins). This should be confirmed against the Application Auto Scaling target tracking documentation before relying on it.

---

## Exercise 2 - Intermediate: the scale-in half of step scaling, and a fight to avoid

`templates/lab-06-step-scaling-in.json`:

```json
{ "AdjustmentType": "ChangeInCapacity", "MetricAggregationType": "Average", "Cooldown": 300,
  "StepAdjustments": [
    { "MetricIntervalLowerBound": -10, "MetricIntervalUpperBound": 0, "ScalingAdjustment": -1 },
    { "MetricIntervalUpperBound": -10, "ScalingAdjustment": -2 } ] }
```

**Signs, and why:** bounds are relative to the alarm threshold (20), and the alarm fires *below* it, so every breach is **negative**. That makes all bounds **non-positive**. Adjustments are **negative** because this policy removes capacity.

- `MetricIntervalUpperBound: 0` with `LowerBound: -10` and `ScalingAdjustment: -1` means: metric between 10 and 20 (a breach of 0 to −10), remove **one** task.
- The second step has no lower bound (open-ended downwards): metric below 10, remove **two** tasks.

**Cooldown 300 against 60 for scale-out:** removing capacity too quickly after a spike is what causes the next outage. A long scale-in cooldown waits out a dip before taking tasks away, and keeps scale-in reluctant, as Section 4 requires.

The alarm `usms-enrolment-queue-low` uses `Average`, `LessThanThreshold 20`, 3 periods of 60 s, and has the step-in policy as its only action.

**Observed:**

```text
published 5, 5, 5      breach = 5 - 20 = -15 -> open-ended bottom step -> ScalingAdjustment -2
set-alarm-state ALARM  -> "low alarm forced to ALARM"
poll 1..4              desired/running = 2 2      (nothing happened)
```

Nothing happened, for two reasons. On this build no alarm invokes its policy (path B). And on real AWS the result would be the same: 2 − 2 = 0 is clamped to `MinCapacity` 2.

**The unreachable step:** from the baseline of 2, both steps are clamped, and the **−2** step can never take full effect unless the service is already at 4 or more (2 + (−2) = 0 < 2). The −1 step is the only one that can do anything until the count is above 3.

**Deletion, in dependency order (executed):**

> [!CAUTION]
> **What will be deleted:** the CloudWatch alarm `usms-enrolment-queue-low`.
> **What depends on it:** nothing. It is the only thing that invokes `usms-enrolment-queue-step-in`, so it goes **first**; deleting the policy first would leave an alarm whose action names a policy that no longer exists.
> **Reversible?** Yes, with the `put-metric-alarm` command above.
> **Effect on later labs:** none. It is a practice object, not in `configs/lab-06.env`.

```bash
aws cloudwatch delete-alarms --alarm-names usms-enrolment-queue-low
```

> [!CAUTION]
> **What will be deleted:** the step scaling policy `usms-enrolment-queue-step-in`.
> **What depends on it:** nothing, now that its alarm is gone.
> **Reversible?** Yes, with the `put-scaling-policy` command above.
> **Effect on later labs:** none. `verify-lab-06.sh` checks only the scale-out step policy.

```bash
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" \
  --scalable-dimension "$SDIM" --policy-name usms-enrolment-queue-step-in
```

Result: both gone (`length(MetricAlarms)` = 0), the remaining policies are as before, and `verify-lab-06.sh` is still `PASS=39 FAIL=3`.

**Then answer - a step policy on CPU at 60% next to CPU target tracking at 50%:** they fight. Target tracking computes the capacity that would bring CPU to **50%**, proportionally: 4 tasks at 80% → 4 × 80 / 50 = 6.4 → 7. The step policy, at its own 60% threshold, *adds* a fixed number on top. Each move changes the CPU both are reading, so after the step policy overshoots, target tracking sees CPU well under 50% and wants to scale in (blocked, but its proportional answer is now wrong). When CPU sits between 50% and 60%, target tracking keeps pushing out while the step policy is idle. The result is oscillation, or capacity that ratchets up, with neither policy's arithmetic converging. I would keep **target tracking**: it has a set point and computes the right capacity in one move, and its scale-in behaviour is designed to be conservative. Step scaling belongs on metrics without a set point (like the queue), not duplicated on CPU.

---

## Exercise 3 - Problem solving: a scaling report tool

Script: `scripts/utilities/usms-scaling-report.sh`.

- Bash resolves `configs/` from `${BASH_SOURCE[0]}`. Python discovers every scalable target in `ecs` whose cluster starts `usms-`, then its policies, every alarm (one `describe-alarms` call), scheduled actions, activities and the ECS counts.
- **The verdict is computed**, top to bottom: `PINNED` → `FROZEN` → `AT-CEILING` → `AT-FLOOR` → `ELASTIC`.
  - `PINNED` is first because with min = max nothing else matters.
  - `FROZEN` outranks `AT-CEILING` because a suspended target will not move even if a metric demands it. Reporting "at ceiling" would imply the policies are working and merely out of room, which hides the real problem.
- Step adjustments come from the configuration as a signed list (`+1 / +3`).
- An empty `Alarms` list, a target with no policies or scheduled actions, and the unsupported scheduled-action and activity reads all print an explicit line, never a blank row.
- `set -uo pipefail` without `-e`, justified in a comment.
- It writes `outputs/lab-06-scaling-report.json`.

**Identical from `~` and from `labs/lab-06-ecs-autoscaling/`** (after Exercise 1, so four policies):

```text
service/usms-ecs-cluster/usms-enrolment-svc   ecs:service:DesiredCount
  bounds        min=2 max=10  desired=2 running=2                           AT-FLOOR
  suspended     none
  target-track  usms-enrolment-cpu-target-tracking       CPU/50.0       out=60 in=300
                alarms AlarmHigh=INSUFFICIENT_DATA AlarmLow=INSUFFICIENT_DATA
  target-track  usms-enrolment-memory-target-tracking    Memory/70.0    out=60 in=600  (scale-out only)
                alarms AlarmHigh=INSUFFICIENT_DATA AlarmLow=INSUFFICIENT_DATA
  step          usms-enrolment-queue-step-out            +1 / +3        cooldown=60
                alarm usms-enrolment-queue-high = OK  (USMS/Enrolment EnrolmentQueueDepth >= 100)
  target-track  usms-enrolment-requests-target-tracking  ALBReq/1000.0  out=60 in=300
                alarms AlarmHigh=INSUFFICIENT_DATA AlarmLow=INSUFFICIENT_DATA
  scheduled     not readable on this build (Operation DescribeScheduledActions is not supported.)
  last activity not readable on this build
```

**Other states, each set and then restored:**

```text
scale-in suspended   bounds min=2 max=10 desired=2 running=2   FROZEN    suspended DynamicScalingIn
min = max = 3        bounds min=3 max=3  desired=2 running=2   PINNED
restored             2 10 / False False False / desired 2
```

---

## Exercise 4 - Challenge: the enrolment-week capacity plan

*To: the USMS project lead.*

### Is it solved? (three sentences)

Reactive auto scaling is good at following load that rises over minutes, and at handing capacity back when it falls. It is bad at sudden steps, because every reactive decision waits for a metric, an alarm and a new task to pass its health checks, and it can never add more than the ceiling allows. The first twenty minutes of a forty-fold spike are exactly that bad case: on its own, it is **not** solved.

### Why forty times traffic is not a scaling problem

**How long a reactive policy takes from 2 to 10**, with this lab's numbers:

- high alarm 60 s × 3 evaluations = 180 s;
- plus about 0 s to invoke the policy;
- plus about 40 s to start a Fargate task (Lab 05 measured 38.5 s; AWS cites 20-60 s);
- plus 60 s grace and health checks (this lab measured **62.8 s** from `desired 4` to four healthy targets).

That totals **≈ 280 s, about 4.7 minutes**, before the first added task serves. Target tracking computes the whole jump in one step (current × metric / target), so it goes straight to the ceiling. With a 60 s scale-out cooldown, a second adjustment cannot come sooner. For those ~5 minutes, 2 tasks carry 40× load.

**What the ceiling of 10 means at Step 9's target:** 10 tasks × 1000 requests per target per **minute** = 10,000 requests/minute = **≈ 167 requests/second** of *capacity at target*.

**Assumption for throughput:** at normal traffic, 2 tasks run at half their target, 500 requests/minute each, so 1,000 requests/minute ≈ **16.7 req/s** in total. Replace this with real analytics.

40× normal = 40,000 requests/minute ≈ **667 req/s**, which needs 40,000 ÷ 1,000 = **40 tasks** at the target. The ceiling of 10 serves only a quarter of it. **Capacity** (how many tasks may run) is the limit here, not reaction speed. Even an instant scaler would be pinned at 10 while serving 167 req/s of a 667 req/s demand.

### The ceiling, checked against Lab 02's subnets

AWS reserves **5 addresses** in every subnet: the first four and the last. That leaves 256 − 5 = **251 usable** in each `/24`. (Amazon VPC User Guide, "Subnet CIDR blocks": "The first four IP addresses and the last IP address in each subnet CIDR block are not available for your use.")

| Subnet | Usable | Existing occupants | Free for tasks |
|---|---|---|---|
| `usms-private-subnet-a` `10.0.3.0/24` | 251 | `usms-db-01` (1 ENI) | 250 |
| `usms-private-subnet-b` `10.0.4.0/24` | 251 | `usms-db-02` (1 ENI) | 250 |

Each Fargate task in `awsvpc` mode takes one address, so the subnets support about **500 tasks**, or 250 per AZ if the service must stay balanced. A ceiling of 45 uses under 10% of that. The binding limits are the account's **Fargate On-Demand vCPU quota** (45 tasks × 0.25 vCPU = 11.25 vCPU, which fits default quotas but should be checked in Service Quotas) and, above all, the database behind the service.

### The capacity plan

*Assumption:* enrolment opens at **08:00 Asia/Thimphu**. The three cohort days are the **14th, 21st and 28th** (the start of each week); the window is the 14th to the 4th of the following month. Confirm the dates (below).

| Action | Schedule (time zone `Asia/Thimphu`) | Bounds | Why |
|---|---|---|---|
| `usms-enrolment-window-open` | `cron(0 6 14 JAN ? 2027)` | min 4, max 45 | Roughly 2× normal traffic for three weeks, so double the floor; raise the ceiling before any spike |
| `usms-enrolment-cohort-prewarm` | `cron(45 7 14,21,28 JAN ? 2027)` | min 40, max 45 | 40× traffic needs 40 tasks at target. Pre-warmed 15 minutes early, because reactive scaling needs about 5 |
| `usms-enrolment-cohort-release` | `cron(30 9 14,21,28 JAN ? 2027)` | min 4, max 45 | After the first hour, hand control back to target tracking at the window's floor |
| `usms-enrolment-window-close` | `cron(0 22 4 FEB ? 2027)` | min 2, max 10 | Back to the Lab 04 baseline |

- **Target value:** keep `ALBRequestCountPerTarget` 1000 **until a load test says what one task can actually serve**, then set the target at about 70% of that.
- **Reversibility:** every row is reversible in one command (`delete-scheduled-action`, followed by `register-scalable-target --min-capacity 2 --max-capacity 10` to put the floor back). Changing `TargetValue` is one `put-scaling-policy`.
- **On this build** none of these can be created (`put-scheduled-action` is unsupported), so the plan is specified here for real AWS.

### Monthly cost estimate

Prices:

- **AWS Fargate Pricing, us-east-1 Linux/x86** (aws.amazon.com/fargate/pricing/): USD 0.04048/vCPU-hour and USD 0.004445/GB-hour. The `256`/`512` task size from `configs/lab-04.env` costs **USD 0.0123425 per task-hour**.
- **Amazon CloudWatch Pricing** (aws.amazon.com/cloudwatch/pricing/): standard-resolution alarm USD 0.10/alarm-month; custom metric USD 0.30/metric-month; `PutMetricData` USD 0.01 per 1,000 requests.

*Re-check the live pages before sending to Finance.*

| Item | Derivation | USD |
|---|---|---|
| Window floor 4 instead of 2 | 2 extra tasks × 21 days × 24 h = 1,008 task-h × 0.0123425 | 12.44 |
| Cohort pre-warm 40 instead of 4 | 36 extra × 1.75 h (07:45-09:30) × 3 days = 189 task-h × 0.0123425 | 2.33 |
| Reactive headroom above the floors | Assume 6 extra tasks for 6 h/day on 15 weekdays = 540 task-h × 0.0123425 | 6.66 |
| CloudWatch alarms | 5 alarms (4 managed + 1 custom) × 0.10 | 0.50 |
| Custom metric | 1 metric × 0.30, plus publishing every 60 s ≈ 43,800 calls × 0.01/1,000 = 0.44 | 0.74 |
| **Additional cost for the enrolment month** | | **≈ 22.67** |

The baseline service (2 tasks, about USD 18/month) and the load balancer (about USD 24/month, Lab 05) are unchanged.

### What I need from you

1. **The exact cohort dates and opening times**, and who tells us if they move. A scheduled action is only as good as its calendar.
2. **A load-test measurement nobody has taken:** how many requests per second *one* enrolment task serves at acceptable latency. Section 11 notes that the target value of 1000 per minute is provisional, and the target value, the 40-task figure and the cost all depend on it.
3. **Approval to raise the ceiling to 45 for the window** (and the Fargate vCPU quota if needed), plus confirmation that the **database** can take 40 tasks' connections, because scaling the web tier past what the database accepts only moves the outage.

### The tidy-up

> [!CAUTION]
> **What will be deleted:** the target tracking policy `usms-enrolment-memory-target-tracking` (Exercise 1), and with it its managed alarms.
> **What depends on it:** nothing. It is not in `configs/lab-06.env`, and the CPU, request and step policies are independent of it.
> **Reversible?** Yes, with Exercise 1's `put-scaling-policy` and `templates/lab-06-target-tracking-memory.json`.
> **Effect on later labs:** none. Section 15 lists it under CLEAN UP.

```bash
aws application-autoscaling delete-scaling-policy --service-namespace ecs --resource-id "$RID" \
  --scalable-dimension "$SDIM" --policy-name usms-enrolment-memory-target-tracking
```

**Anything left from Exercise 2:** nothing. `usms-enrolment-queue-low` and `usms-enrolment-queue-step-in` were deleted in Exercise 2, in dependency order, each under its own admonition (above).

**Executed:**

```text
managed alarms before: 6
deleted usms-enrolment-memory-target-tracking
managed alarms after : 4     (the policy's alarms went with it)
Exercise 2 leftovers : step-in policy 0, queue-low alarm 0
remaining            : cpu-target-tracking, queue-step-out, requests-target-tracking
verify-lab-06.sh     : PASS=39 FAIL=3  (only the three unsupported scheduled-action checks)
```

---

## Exercise 5 - Integration: the hand-off to Lab 10

**1-2.** `scripts/utilities/usms-scaling-history.sh` discovers the cluster (`usms-` prefix), the enrolment service, and its resource ID (`${ARN##*:}` equivalent). It then exports into one JSON document:

- the scalable target;
- every policy;
- every scheduled action;
- every involved alarm (each policy's managed alarms plus any alarm whose actions name a policy ARN);
- every scaling activity (`--include-not-scaled-activities`).

It adds `"generated"` (UTC, from Python) and `"resourceId"`, and validates with `python3 -m json.tool`. Unsupported reads are recorded as `{"_unavailable": "..."}` rather than omitted.

```text
/home/kp/Desktop/DSO303/aws-floci-course/outputs/lab-06-scaling-history.json 12007 bytes
resourceId service/usms-ecs-cluster/usms-enrolment-svc | 3 policies | 5 alarms
scheduledActions / scalingActivities: _unavailable (UnsupportedOperation on Floci 1.7)
```

**3. Scale-out latency** (`outputs/lab-06-scale-latency.txt`):

- **As specified** (re-register `MinCapacity` 2 → 4 and poll): not observable. Floci does not enforce the floor, so `desiredCount` stayed 2. The floor was put back to 2.
- **Measured instead** (`update-service --desired-count 2 → 4`, the integer a policy would write):
  - start `2026-10-13T19:39:16Z`, end `2026-10-13T19:39:23Z`, capacity 2/2 → 4/4;
  - **running after 7.4 s**, and **serving (4 healthy targets) after 62.8 s**;
  - then put back to 2.
- **AWS's cited figure:** Fargate start-up 20-60 s, then 30 s × 2 health checks, so about 60-120 s to serving capacity.

**4.** Appended to `configs/lab-06.env`, derived rather than typed: `USMS_SCALING_HISTORY_FILE=outputs/lab-06-scaling-history.json` and `USMS_SCALE_LATENCY_SECONDS=62.8`. The empty-value check gives `all values populated`, with **24** exports.

**5-6. `outputs/lab-06-lab10-readiness.txt`** (committed copy: `labs/lab-06-ecs-autoscaling/lab10-readiness.txt`):

```text
history file     : outputs/lab-06-scaling-history.json (12007 bytes, valid JSON: yes)
scale latency    : 62.8s to serving capacity (running after 7.4s)
task role ARN    : arn:aws:iam::000000000000:role/usms-ecs-task-role
bucket ARN       : arn:aws:s3:::usms-student-data   (read with get-policy-version from
                   USMSStudentDataReadWrite v1, statement ListTheBucketItself; the object ARN
                   arn:aws:s3:::usms-student-data/* is the second Resource)
permissions      : s3:ListBucket and s3:GetBucketLocation on the bucket, s3:GetObject/PutObject/
                   DeleteObject on its objects, and an explicit Deny on s3:DeleteBucket
head-bucket      : An error occurred (404) when calling the HeadBucket operation: Not Found
head-bucket exit : 254
after Lab 10 Step 1: head-bucket returns exit 0, and usms-ecs-task-role's existing policy starts
                   applying to a real bucket - with no change to the role, task definition or service.
```

I recorded the **bucket** ARN (`arn:aws:s3:::usms-student-data`), the Resource of the `ListTheBucketItself` statement, because `head-bucket` and `create-bucket` act on the bucket itself. The object ARN (`…/*`) governs the `put-object` Lab 10 will run next. No script contains, reads or references an access key.
