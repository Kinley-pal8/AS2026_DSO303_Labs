# Lab 04 - Independent Exercises

All commands were run from `aws-floci-course/` against Floci 1.7.0 with `configs/course.env`, `lab-01.env` to `lab-04.env` sourced. Full captured output is in `outputs/lab-04-ex*.txt` (git-ignored).

---

## Exercise 1 - Basic: a second service, deployed

Every ID comes from `configs/lab-02.env` / `lab-04.env`, and the ARN is captured with `--query`:

```bash
RESULTS_ARN=$(aws ecs create-service \
  --cluster "$USMS_ECS_CLUSTER" --service-name usms-results-svc \
  --task-definition "$USMS_ENROLMENT_TASK_FAMILY" --desired-count 1 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$USMS_PRIVATE_SUBNET_A,$USMS_PRIVATE_SUBNET_B],securityGroups=[$USMS_ENROLMENT_SG],assignPublicIp=DISABLED}" \
  --enable-ecs-managed-tags --propagate-tags SERVICE \
  --tags key=Name,value=usms-results-svc key=Project,value=USMS key=Tier,value=app key=Lab,value=04 key=Service,value=results \
  --query 'service.serviceArn' --output text)
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" --services usms-results-svc
```

```text
RESULTS_ARN = arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-results-svc
results service stable
+---------+----------------------+----------+----------+
| Desired |        Name          | Running  | Status   |
+---------+----------------------+----------+----------+
|  2      |  usms-enrolment-svc  |  2       |  ACTIVE  |
|  1      |  usms-results-svc    |  1       |  ACTIVE  |
+---------+----------------------+----------+----------+
```

There are two `ACTIVE` services with different names and desired counts. `usms-results-svc` was deliberately **not** recorded in `configs/lab-04.env`, and Exercise 4 removes it.

---

## Exercise 2 - Intermediate: a new revision, and a deployment that does not drop traffic

`templates/lab-04-taskdef.json` (revision 1) was left untouched. A copy, `templates/lab-04-taskdef-rev2.json`, changes exactly two things:

```text
<     "memory": "512",
>     "memory": "1024",
>                 { "name": "USMS_LOG_LEVEL", "value": "info" }
```

It is valid JSON with no unexpanded `$`, and 256 CPU / 1024 MiB is a valid Fargate pair.

```bash
aws ecs register-task-definition --cli-input-json file://templates/lab-04-taskdef-rev2.json \
  --query 'taskDefinition.taskDefinitionArn' --output text
# arn:aws:ecs:us-east-1:000000000000:task-definition/usms-enrolment:2
aws ecs update-service --cluster usms-ecs-cluster --service usms-enrolment-svc --task-definition usms-enrolment:2
aws ecs wait services-stable --cluster usms-ecs-cluster --services usms-enrolment-svc   # service stable
```

```text
describe-services        TaskDef: usms-enrolment:2   Desired: 2  Running: 2
                         Deployments: [ PRIMARY usms-enrolment:2 running 2 ]
describe-task-definition usms-enrolment:1  -> Rev 1, Status ACTIVE, Memory 512
describe-task-definition usms-enrolment:2  -> Rev 2, Status ACTIVE, Memory 1024,
                         env USMS_SERVICE, USMS_BUCKET, AWS_REGION, USMS_LOG_LEVEL
```

**What changes and what does not:** the service's `taskDefinition` field (its pointer) changes from revision 1 to revision 2, while revision 1 itself is never modified and stays `ACTIVE` and describable, because a revision is immutable and deregistering it is a separate action.

**Why this deployment would not drop traffic on real AWS:** with the default deployment configuration (`minimumHealthyPercent` 100, `maximumPercent` 200), ECS starts two `:2` tasks *before* stopping any `:1` task, so capacity never falls below `desiredCount`. With a load balancer (Lab 05), old tasks are also drained of in-flight connections before stopping.

**Floci limitation observed:** Floci updated the pointer and reported a single `PRIMARY` deployment on `:2`, but **never replaced the running tasks**, not even with `--force-new-deployment`. `describe-tasks` and `docker inspect` both showed the two running containers were still the original `:1` tasks, without `USMS_LOG_LEVEL`. On real AWS, `describe-tasks` would show `taskDefinitionArn …:2` on both running tasks within a minute or two.

---

## Exercise 3 - Problem solving: an ECS configuration drift report

Script: `scripts/utilities/lab-04-ecs-inventory.sh`.

- It lists the services in the cluster with `list-services` (no hard-coded name).
- It describes each service, then describes the task definition that service points at.
- It computes the verdicts:

| Column | Rule |
|---|---|
| `roles` | `SAME` if `executionRoleArn` == `taskRoleArn`; `SEPARATE` if they differ; `MISSING` if either is absent; `N/A` if no task definition |
| `publicip` | `RISK` if `assignPublicIp` is `ENABLED`; `OK` if `DISABLED`; `N/A` if there is no `networkConfiguration` (for example an `EC2` launch type service) |

- It runs from any directory, because `configs/` is resolved from `${BASH_SOURCE[0]}`.
- The CLI's literal `None` is normalised, so no field is ever printed empty.
- The service's task definition is shown as `family:revision`, whether ECS returns a full ARN (real AWS) or a bare name (Floci).
- `set -uo pipefail` **without `-e`**, justified in the script: a service may legitimately lack fields, and one odd service must not abort the report for the others.
- It writes the same data as JSON to `outputs/lab-04-ecs-inventory.json`.

**Identical output from `~` and from `labs/lab-04-ecs/`** (`diff` empty):

```text
usms-enrolment-svc   desired=2  running=2  taskdef=usms-enrolment:2   roles=SEPARATE publicip=OK
usms-results-svc     desired=1  running=1  taskdef=usms-enrolment     roles=SEPARATE publicip=OK
```

**Proving the other two verdicts are computed, not assumed.** A temporary task definition family `usms-legacy` (with `taskRoleArn` set equal to `executionRoleArn`) and a service `usms-legacy-svc` (with `assignPublicIp=ENABLED`) were created, reported on, and then removed:

```text
usms-legacy-svc      desired=1  running=1  taskdef=usms-legacy        roles=SAME     publicip=RISK
usms-results-svc     desired=1  running=1  taskdef=usms-enrolment     roles=SEPARATE publicip=OK
usms-enrolment-svc   desired=2  running=2  taskdef=usms-enrolment:2   roles=SEPARATE publicip=OK
== removing the temporary test service and family
0 / INACTIVE / INACTIVE
```

---

## Exercise 4 - Challenge: the enrolment week capacity plan

### Why a fixed `desiredCount` of 2 cannot answer the 08:03 problem

`usms-enrolment-svc` reads no metric and no clock. Its `desiredCount` is a number a human typed (Step 10, and again in Step 11's "Your turn"), and the service's only job is to keep `runningCount` equal to it. At 08:00 on Monday the load rises by an order of magnitude, but nothing in the system observes that, so two tasks absorb a peak sized for ten, saturate, and fail health checks. That is exactly the 11-minute outage at 08:03. It would only end when someone noticed and ran `update-service`, and even then each new Fargate task takes 20 to 60 seconds to start. A service that never changes its count can only be sized for the peak (and pay for it at 3 a.m. on a Sunday in July) or for the average (and fall over at 08:03). It cannot be both.

### The demand estimate, and how it was derived

| Quantity | Value | Derivation |
|---|---|---|
| Students registering | 6,000 | Planning assumption for the USMS student body; **replace with the Registrar's actual figure** |
| Modules per student | 5 | Typical semester load |
| API calls per module registration | 4 | List modules, check prerequisites, submit, confirm |
| Requests in enrolment week | 120,000 | 6,000 × 5 × 4 |
| Requests in the first 20 minutes | 108,000 | 90% of 120,000 (the project lead's figure) |
| Average rate, 08:00 to 08:20 | 90 req/s | 108,000 ÷ 1,200 s |
| Peak rate, 08:00 to 08:05 | 180 req/s | 2× the 20-minute average: the first five minutes are always the steepest (and 08:03 is when it broke) |
| Capacity of one 256/512 task | 25 req/s | Planning figure (the lab's example); **must be confirmed by a load test of one task** before Lab 06 |
| Tasks for the peak | 8 | ⌈180 ÷ 25⌉ = 8 |
| Plus headroom | +1 → 9 | One task can be lost or still starting without overload |
| Rounded for two AZs | **10** | An even count keeps the two Availability Zones balanced (5 + 5); losing a whole AZ still leaves 5 × 25 = 125 req/s, enough for the 20-minute average |

### The plan for Lab 06 (not implemented here)

| Setting | Value | Why | Cost of too high / too low |
|---|---|---|---|
| **Minimum** | 2 | One task per AZ, so a single AZ failure never takes the service to zero | Too high: paying peak-ish prices all of July. Too low (1): an AZ outage or one task crash is a full outage |
| **Scheduled floor** | 10 tasks, Monday of enrolment week **07:45 to 08:30** | Pre-warms before the spike. Reactive scaling cannot help at 08:00, because a metric must breach for 1 to 3 minutes, then tasks take 20 to 60 s to start, which lands at about 08:03, the moment it failed last year | Too high: only about 45 minutes of extra tasks, a few cents. Too low: a repeat of 08:03 |
| **Maximum** | 12 | Peak 10 + 20% for an estimate error. It also caps the bill if a bug or bot drives CPU up | Too high: a runaway can scale cost unchecked. Too low: real demand above the estimate is refused |
| **Target tracking** | Average CPU 60% (`ECSServiceAverageCPUUtilization`) | Leaves about 40% headroom for the 20 to 60 s it takes a new task to arrive; handles the rest of the week reactively | A higher target saves money but leaves no time for new tasks; a lower one runs more tasks than needed |
| Scale-out / scale-in cooldown | 60 s / 300 s | Add capacity fast, remove it slowly so a dip does not cause flapping | |

Note for the Lab 06 team: on this Floci build `describe-scheduled-actions` is `UnsupportedOperation` and Container Insights settings are not stored (see `notes/lab-04-notes.md`). The scheduled floor and the CPU metric will need the documented fallbacks on Floci, but the **shape** above is what to configure.

### Monthly cost comparison

Prices from **AWS Fargate Pricing, US East (N. Virginia), Linux/x86** (aws.amazon.com/fargate/pricing/): **USD 0.04048 per vCPU-hour** and **USD 0.004445 per GB-hour**. *Re-check the live page before sending to Finance.*

One `256`/`512` task-hour = 0.25 × 0.04048 + 0.5 × 0.004445 = 0.01012 + 0.0022225 = **USD 0.0123425**. A month is 730 hours.

| Option | Calculation | USD / month |
|---|---|---|
| **A. Fixed at today's 2** | 2 × 730 × 0.0123425 | **18.02**, and it falls over at 08:03 |
| **B. Fixed at the proposed peak, 10** | 10 × 730 × 0.0123425 | **90.10**, and it survives 08:03 but is idle at 3 a.m. all July |
| **C. The plan** (min 2, scheduled floor 10 for 45 min, target tracking) | 18.02 base + 8 extra tasks × 0.75 h × 0.0123425 = 0.07 for the window. Allow about 2 extra tasks for 20 h of enrolment week for the reactive tail: 2 × 20 × 0.0123425 = 0.49 | **≈ 18.59** in enrolment month, **18.02** in other months |

Option C costs about 3% more than today and about 80% less than running at peak permanently. It is the only option that answers both the Registrar (no 08:03 outage) and Finance (no peak capacity at 3 a.m. in July). The load balancer added in Lab 05 is a separate line item that is the same under all three options.

### What to switch off: the Exercise 1 results service

> [!CAUTION]
> **What will be deleted:** `usms-results-svc`, the Exercise 1 practice service. First it is scaled to 0 so its task stops gracefully.
> **What depends on it:** nothing. It is not in `configs/lab-04.env`, has no load balancer, and Section 15 lists it under CLEAN UP.
> **Reversible?** The service object is not (it goes `INACTIVE`), but it can be recreated from Exercise 1's command in seconds. The task definition and cluster are untouched.
> **Effect on later labs:** none. Lab 05 and Lab 06 use `usms-enrolment-svc` only.

```bash
aws ecs update-service --cluster usms-ecs-cluster --service usms-results-svc --desired-count 0
aws ecs wait services-stable --cluster usms-ecs-cluster --services usms-results-svc
```

> [!CAUTION]
> **What will be deleted:** the `usms-results-svc` service object itself, now running zero tasks.
> **What depends on it:** nothing (as above).
> **Reversible?** No. A deleted service goes `INACTIVE` and cannot be reactivated, only recreated.
> **Effect on later labs:** none.

```bash
aws ecs delete-service --cluster usms-ecs-cluster --service usms-results-svc
```

**Executed:**

```text
$ aws ecs update-service --cluster usms-ecs-cluster --service usms-results-svc --desired-count 0
{ "Name": "usms-results-svc", "Desired": 0 }
$ aws ecs wait services-stable --cluster usms-ecs-cluster --services usms-results-svc
drained to 0
$ aws ecs delete-service --cluster usms-ecs-cluster --service usms-results-svc
{ "Name": "usms-results-svc", "Status": "INACTIVE" }
$ aws ecs list-services --cluster usms-ecs-cluster
arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-enrolment-svc
$ ./scripts/utilities/verify-lab-04.sh | tail -1
PASS=38  FAIL=0
```

Nothing in Section 15's KEEP column was touched.

---

## Exercise 5 - Integration: close the loop back to Lab 3, and hand Lab 05 what it needs

**1. Reverse lookup.** `usms-enrolment-sg`'s only inbound source is `sg-d65bcc7ad6230c0b3` (`usms-app-sg`). The lab's server-side form:

```bash
aws ec2 describe-instances --filters "Name=instance.group-id,Values=sg-d65bcc7ad6230c0b3" \
  "Name=instance-state-name,Values=running" --query 'Reservations[].Instances[].InstanceId' --output text
```

On this build, that returned all 4 running instances. Floci ignores `instance.group-id` (a non-existent group ID returns every instance), so the result was not used as evidence, and the lookup was done client-side instead:

```bash
aws ec2 describe-instances \
  --query "Reservations[].Instances[?State.Name=='running' && SecurityGroups[?GroupId=='sg-d65bcc7ad6230c0b3']][].[InstanceId,Tags[?Key=='Name']|[0].Value]" \
  --output text
# i-b617e94be1c24637e   usms-web-01
# i-fee3fe4304bdc1f02   usms-web-02
```

**2. Comparison with `configs/lab-03.env`.** `USMS_WEB_INSTANCE=i-b617e94be1c24637e` is in the result, so the verdict is **LOOP CLOSED**. A second instance also carries the group: `usms-web-02`, launched deliberately in Lab 03 Step 18 "Your turn" as a second web server in `us-east-1b`. It is an expected second caller of the enrolment API, not drift, and it is recorded as such rather than glossed over.

**3. `outputs/lab-04-lab03-linkage.txt`** contains the source group, the instances it resolves to, the verdict, and the sentence: *"This rule is temporary: Lab 05 removes it once the load balancer becomes the only caller of the enrolment service."* `outputs/` is git-ignored, so an identical copy is committed at `labs/lab-04-ecs/lab03-linkage.txt` so that a Lab 05 reader can open it.

**4. Tag audit** with `aws ecs list-tags-for-resource --resource-arn <ARN>` (an ARN, not a name), appended to the same file:

```text
-- arn:aws:ecs:us-east-1:000000000000:cluster/usms-ecs-cluster
   Project USMS / Tier app / Name usms-ecs-cluster
-- arn:aws:ecs:us-east-1:000000000000:service/usms-ecs-cluster/usms-enrolment-svc
   Project USMS / Tier app / Lab 04 / Name usms-enrolment-svc
-- arn:aws:ecs:us-east-1:000000000000:task-definition/usms-enrolment:1
   Project USMS / Tier app / Lab 04 / Name usms-enrolment
```

Every ECS resource stored its tags on this build, so no `tag-resource` repair was needed.
