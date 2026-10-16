# Lab 06 Notes

## Support path (Step 3): **Path B - control plane only**

Floci 1.7.0 stores scalable targets, both kinds of scaling policy, their managed alarms and my custom alarm, and it persists all of them across a restart. **It does not run the scaling loop:**

- `set-alarm-state … ALARM` changed the alarm's state (Floci logged `SetAlarmState: usms-enrolment-queue-high -> ALARM`), but no policy was invoked and `desiredCount` stayed at 2 for 100 seconds.
- A metric pushed to 260 was stored (`get-metric-statistics` showed `Average 260.0`), but the alarm was never evaluated: it stayed `INSUFFICIENT_DATA`, `Unchecked`.
- Raising `MinCapacity` to 5 (and to 4 in Exercise 5) did not raise `desiredCount`.
- `describe-scaling-activities`, `describe-scheduled-actions` and `put-scheduled-action` all return `UnsupportedOperation`.

Step 12's proof is therefore the six-block **control-plane chain** in `outputs/lab-06-scaling-proof.txt`. No scaling activity is claimed.

## Step 6 "Your turn": MinCapacity 5 while two tasks run

**Prediction:** `desiredCount` moves from 2 to 5 within seconds, with no policy or alarm involved. **Observed on Floci:** it stayed at 2 for 40 seconds, because Floci does not enforce the floor, and `describe-scaling-activities` is unsupported, so whether it would have been recorded is unobservable.

(a) The **scalable target** made (or, on real AWS, would make) that change: its registration enforces `MinCapacity` directly, with no scaling policy or ECS decision involved.
(b) The cost is three extra Fargate tasks running all night (3 × 0.0123425 USD/h for the 256/512 size, about USD 0.89 a night, and more importantly a floor nobody knows about). The single call that would have told me is `aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids service/usms-ecs-cluster/usms-enrolment-svc --query 'ScalableTargets[0].MinCapacity'`, compared by a monitor against the expected 2.

## Step 8 "Your turn": how long at 100% CPU before a third task serves traffic

| Term | Value | Where it comes from |
|---|---|---|
| High alarm `Period × EvaluationPeriods` | 60 s × 3 = **180 s** | The managed alarm (AWS's choice, not this lab's) |
| Policy invocation | **≈ 0 s** | Application Auto Scaling |
| Task start-up | **≈ 40 s** (Lab 05 measured 38.5 s to healthy; AWS cites 20-60 s; this lab measured 7.4 s to `RUNNING` on Floci) | Fargate, not this lab |
| Grace period / first health checks | **60 s** | Lab 05 Step 10's `healthCheckGracePeriodSeconds` (and 30 s × 2 healthy threshold) |
| **Total** | **≈ 280 s, about 4.7 minutes** | |

I would change the **180-second alarm evaluation** first. The managed alarm cannot be edited, so it means scaling on my own alarm with one evaluation period (step scaling, as Step 10 did) or on a faster-moving metric such as requests per target. The cost is reacting to one noisy minute: more scale-outs that were not needed, and more oscillation.

## Step 11: scheduled actions could not be created

`put-scheduled-action` returns `UnsupportedOperation` on Floci 1.7, both with `--timezone Asia/Thimphu` and in the UTC fallback, so neither action nor the `at()` "Your turn" exists. These are the commands that would run on real AWS:

```bash
aws application-autoscaling put-scheduled-action --service-namespace ecs \
  --resource-id service/usms-ecs-cluster/usms-enrolment-svc --scalable-dimension ecs:service:DesiredCount \
  --scheduled-action-name usms-enrolment-morning-scale-out --schedule "cron(45 7 ? * MON-FRI *)" \
  --timezone "Asia/Thimphu" --scalable-target-action MinCapacity=4,MaxCapacity=10
aws application-autoscaling put-scheduled-action ... --scheduled-action-name usms-enrolment-evening-scale-in \
  --schedule "cron(0 20 ? * MON-FRI *)" --timezone "Asia/Thimphu" --scalable-target-action MinCapacity=2,MaxCapacity=10
# Your turn (one-off):
aws application-autoscaling put-scheduled-action ... --scheduled-action-name usms-enrolment-results-night \
  --schedule "at(2026-10-14T01:35:00)" --timezone "Asia/Thimphu" --scalable-target-action MinCapacity=6
```

**"Your turn" answer:** after it fires, an `at()` action stays in `describe-scheduled-actions` as a dead calendar entry, and the floor it raised to 6 *stays* at 6, because deleting or expiring an action never undoes the change it made. Six months later nobody remembers why the service will not scale below 6, or someone copies the stale action as a template. The runbook page that creates it should therefore also hold `aws application-autoscaling delete-scheduled-action … --scheduled-action-name usms-enrolment-results-night`, followed by the `register-scalable-target … --min-capacity 2 --max-capacity 10` that puts the floor back.

## Step 15: the nine-line chain (Review Question 1)

1. A student clicks Register; requests per target rise past 1000, or the work queue passes 100. *(this lab: the metric choice and threshold)*
2. An alarm fires and invokes a policy. *(this lab: policies and alarms)*
3. The policy writes `desiredCount`, clamped to 2..10. *(this lab: the scalable target)*
4. ECS starts a task from `usms-enrolment:2`. *(Lab 04)*
5. The task gets an ENI in `usms-private-subnet-a` or `-b`, with no public address. *(Lab 02 + Lab 04)*
6. `usms-enrolment-sg` admits tcp/80 from `usms-alb-sg` only. *(Lab 05)*
7. The service registers its address in `usms-enrolment-tg`. *(Lab 05)*
8. The load balancer health-checks it, and after the grace period it takes traffic. *(Lab 05)*
9. Nothing about the blueprint, the service or the load balancer changed. *(Step 15 block 7: `usms-enrolment:2`, 1 load balancer, 1 deployment)*

This lab owns lines 1-3 only.

## Floci limitations hit in this lab (Floci 1.7.0)

| What happened on Floci | What real AWS would have done |
|---|---|
| `create-service-linked-role` created **`AWSServiceRoleForEcsApplicationAutoscaling`** (wrong name, no policy attached), while the scalable target's `RoleARN` names **`AWSServiceRoleForApplicationAutoScaling_ECSService`**, which does not exist on this build | One role, `AWSServiceRoleForApplicationAutoScaling_ECSService`, with `AWSApplicationAutoscalingECSServicePolicy`, used for every `UpdateService` |
| Registering with `MinCapacity` above the current count did not raise `desiredCount` | `desiredCount` raised to the floor immediately |
| Managed alarms: `MetricName` is the predefined type name (`ECSServiceAverageCPUUtilization`, `ALBRequestCountPerTarget`), namespace `AWS/ECS` for both, no dimensions, and **both** thresholds equal the target (no lower dead band) | `AWS/ECS CPUUtilization` and `AWS/ApplicationELB RequestCountPerTarget` with `ClusterName`/`ServiceName` or `TargetGroup` dimensions; the low alarm sits below the target |
| A `DisableScaleIn: true` policy still got an `AlarmLow` (managed alarms 4 → **6**, not 5) | Only the high alarm is created |
| `TreatMissingData notBreaching` was not stored (`null`) | Stored and applied |
| The step policy's `Alarms` list stays empty even though my alarm's `AlarmActions` names it | The policy lists the alarm that invokes it |
| Alarms are never evaluated (`INSUFFICIENT_DATA`, `Unchecked`), and `set-alarm-state ALARM` invokes no action | Evaluated every period; the state change invokes the policy within seconds |
| `put-scheduled-action`, `describe-scheduled-actions` and `describe-scaling-activities` return `UnsupportedOperation` | Fully supported; activities record `Cause` naming the alarm and policy |
| `healthCheckGracePeriodSeconds` reads `None` (carried over from Lab 05) | 60 |
| After the Step 14 restart all four EC2 instances came back `stopped`, and the target group held two addresses of tasks that no longer existed (`unhealthy`, `Target.FailedHealthChecks`). I started the instances one at a time and deregistered only the two addresses with no container behind them (`outputs/lab-06-step14-orphans.txt`) | Nothing on the operator's laptop affects either |

**Lab text bugs:**

- Step 16's `awk -F: '{print \$NF}'` inside `$( … )` in an unquoted heredoc keeps its backslash, and awk rejects `\$NF`. I derived the resource ID with Step 5's own `${SVC_ARN##*:}` instead.
- Step 17's blanket replacement of `lab-04-cleanup.sh` → `lab-06-cleanup.sh` would also have broken three *correct* lines in `lab-05-cleanup.sh` ("Run BEFORE lab-04", "lab-04 may now run"). Only the three stale hints were changed, and `lab-04-cleanup.sh` already said `lab-06`.
- The verify script's `no secret is tracked by git` check got the same one-line `outputs/.gitkeep` fix as Labs 04 and 05.

**Verification:** `verify-lab-06.sh` reports `PASS=39 FAIL=3`. All three failures are the scheduled-action checks, caused by the unsupported API; the lab's benign table covers this. `verify-lab-05.sh` output is byte-identical to the Step 2 capture.

## Review Questions

### 1. What does auto scaling change about my application?

The nine lines are listed above. This lab owns lines 1-3: the metric and threshold, the alarm and policy, and the scalable target that clamps one integer. The other six needed no change because ECS was already built to reconcile `runningCount` to whatever `desiredCount` says (Lab 04 Step 11 proved this by hand), and the load balancer was already built to take tasks the service registers (Lab 05 Step 11 proved this at 2 → 3 → 2). Every downstream behaviour (new ENIs, security groups, target registration, health checks) is triggered by a changed count, regardless of who changed it. **In one sentence: auto scaling changes nothing about my application except who is allowed to type the number of copies of it.**

### 2. The resource ID is a constructed string, not an ARN

The resource ID is Application Auto Scaling's own address for "the thing whose dimension may move". For ECS it is `service/<cluster>/<service>`, which is exactly the part of the service ARN after the last colon. Application Auto Scaling uses a constructed string because it is one API over many services, each with different ARN formats, and it needs a uniform `<namespace>` + `<resource-id>` + `<dimension>` triple. The full ARN fails validation because it is not in that format. The form differs per namespace:

- `ecs`: `service/<cluster>/<service>`
- `dynamodb`: `table/<table>` (or `table/<table>/index/<index>`)
- `lambda`: `function:<function-name>:<alias>`

Other constructed identifiers in this architecture:

- The **`ResourceLabel`** (`app/<alb>/<id>/targetgroup/<tg>/<id>`), from the load balancer ARN and the target group ARN.
- The **managed alarm names** (`TargetTracking-<resource-id>-AlarmHigh-<uuid>`), from the resource ID.
- The **scaling policy ARN**, which embeds `resource/ecs/<resource-id>:policyName/<name>`.

### 3. A floor that moves the count

The **scalable target** made that change. Registration enforces `MinCapacity` as a constraint, immediately and unconditionally. A policy, by contrast, *decides* a new capacity from a metric through an alarm, respects cooldowns, and leaves a scaling activity whose `Cause` names the alarm and policy. A floor change only says the count was raised to meet the minimum. (On this Floci build the floor was stored but not enforced.)

**The incident:** at 3 a.m. the enrolment API is degrading, the on-call engineer suspects the policies are scaling in too eagerly, and raises `MinCapacity` to 6 so the service cannot fall below six tasks while they investigate. The person taking over at 8 should find:

- `describe-scalable-targets` showing `MinCapacity 6`;
- a scaling activity "Setting desired count to 6" with no alarm in its cause;
- CloudTrail's `RegisterScalableTarget` call with the engineer's identity and time;
- ideally, an incident note. Without the note, the only clue is a floor that no longer matches the documented 2.

### 4. Managed alarms versus my alarm, and the case for `breaching`

The two target tracking alarms are **owned by Application Auto Scaling**. It creates them, overwrites any edit at the next `put-scaling-policy`, and deletes them with the policy (observed in Exercise 4: deleting the memory policy took its two alarms with it, 6 → 4). If one is deleted by hand, that policy silently stops scaling in one direction, while `describe-scaling-policies` still lists the alarm. `usms-enrolment-queue-high` is **owned by me**: it survives policy changes, I choose its period, evaluations and threshold, and it can have **several actions** (for example the step policy *and* an SNS topic that pages someone), which a managed alarm cannot. In exchange, I am responsible for it and for removing it when the policy goes.

**The case for `breaching`:** the queue depth metric is published by the application. If the application or its publisher is broken or overwhelmed, the metric *stops arriving* exactly when the queue is probably backing up. With `notBreaching` that silence reads as "all fine" and the service never scales. With `breaching`, missing data counts as "queue high" and the service adds capacity when it has lost visibility. **What would go wrong if I were right:** every publisher outage, deployment gap or quiet night without datapoints would scale the service out to the step's +3 (up to the ceiling) for no real load, costing money, and possibly paging people for a monitoring problem rather than a capacity problem.

### 5. Why reactive scaling is always late

The delays, in order:

1. The metric is published and aggregated over its **period** (60 s, set in the alarm).
2. The alarm must see **EvaluationPeriods** consecutive breaches: 3 for the managed high alarm (AWS's choice), 1 for my queue alarm (this lab).
3. The policy is invoked (about 0 s) and must be outside its **cooldown** (`ScaleOutCooldown` 60, this lab).
4. ECS starts a Fargate task: image pull and ENI attachment, 20-60 s (AWS; 38.5 s measured in Lab 05).
5. The load balancer needs **interval × healthy threshold** (30 s × 2, Lab 05 Step 6) to pass it, inside the **grace period** (60 s, Lab 05 Step 10).

The total is roughly 3-5 minutes during which only the capacity that already existed serves the spike. The three consequences:

- **The minimum is a latency decision.** The floor of 2 (one per AZ) absorbs the first minutes of any spike, which justifies `MinCapacity 2`, not 1.
- **Scale out eagerly, scale in reluctantly.** Adding capacity late is an outage, while removing it late is only a small cost, which justifies `ScaleOutCooldown 60` against `ScaleInCooldown 300`.
- **Known spikes need scheduled scaling.** Scheduled actions are the only mechanism that can be *early*, which justifies the 07:45 morning action ahead of the 08:00 opening.

### 6. Two policies that disagree

When the CPU policy at 50 and the request policy at 1000 disagree, **scale-out takes the largest capacity any policy asks for**, while **scale-in happens only when every policy agrees** it is safe. The asymmetry exists because the cost of the two mistakes is asymmetric. Too little capacity is an outage, so any one signal that says "more" is enough. Too much capacity is only money, so removing it needs unanimous evidence. Two target tracking policies on the **same** metric with different targets (say CPU 50 and CPU 70) fight: at 60% CPU one wants more tasks and the other fewer, so the service is pushed out by one and never allowed back in by the other, or it oscillates as each acts in turn. A step policy and a target tracking policy on one metric are the same mistake. Target tracking computes a capacity *proportionally* (current × metric / target), the step policy adds fixed increments at its own threshold, and each move by one changes the metric the other is reading, so they keep overriding each other's arithmetic instead of converging.

### 7. Why requests per target beats CPU for the enrolment API

1. **It measures the cause, not a symptom.** Requests arrive before CPU rises, so the policy reacts to load as it arrives.
2. **It is independent of the task's CPU reservation and code efficiency.** The 256-unit reservation, a runtime change or a faster library changes CPU per request but not demand.
3. **It scales linearly with capacity.** Doubling tasks halves requests per target exactly, which is what target tracking's proportional arithmetic assumes. CPU per task does not fall cleanly when work is not evenly divisible.

CPU is better for **CPU-bound work whose cost per request varies widely**, or work with no load balancer at all: batch and queue workers, report or PDF generation, image processing. `ALBRequestCountPerTarget` would scale this service **badly** if requests had very unequal cost (a few expensive registration transactions among many cheap list calls), or if the bottleneck were **downstream**: the database or a third-party API, where more tasks add load without adding throughput. The metrics that would have warned me are **`TargetResponseTime`** (latency rising while requests per target stays under 1000) and the database's own CPU and connection counts.
