# Lab 05 - Independent Exercises

All commands were run from `aws-floci-course/` against Floci 1.7.0. Captured output is in `outputs/lab-05-ex*.txt` (git-ignored). Section 13.1, the in-class assessment, is done individually and is not part of this file.

---

## Exercise 1 - Basic: a second path through the same load balancer

```bash
RESULTS_TG_ARN=$(aws elbv2 create-target-group --name usms-results-tg --protocol HTTP --port 80 \
  --vpc-id "$USMS_VPC_ID" --target-type ip --health-check-protocol HTTP --health-check-path / \
  --health-check-port traffic-port --matcher HttpCode=200-399 \
  --tags Key=Name,Value=usms-results-tg Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 modify-target-group-attributes --target-group-arn "$RESULTS_TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=15
RESULTS_RULE_ARN=$(aws elbv2 create-rule --listener-arn "$USMS_ALB_LISTENER_ARN" --priority 20 \
  --conditions file://templates/lab-05-ex1-rule-conditions.json \
  --actions file://templates/lab-05-ex1-rule-actions.json \
  --tags Key=Name,Value=usms-results-rule Key=Project,Value=USMS Key=Tier,Value=app Key=Lab,Value=05 Key=Service,Value=results \
  --query 'Rules[0].RuleArn' --output text)
```

The conditions file uses a quoted heredoc, with `/results` and `/results/*`. The actions file uses an unquoted heredoc, so `$RESULTS_TG_ARN` expands (zero `$` remain).

```text
+----------------+----------+----------------------------+-----------+--------------------------------+
|     Action     | Default  |           Paths            | Priority  |               TG               |
+----------------+----------+----------------------------+-----------+--------------------------------+
|  fixed-response|  False   |  /alb-health,/alb-health/* |  10       |  None                          |
|  forward       |  False   |  /results,/results/*       |  20       |  ...targetgroup/usms-results-tg|
|  forward       |  True    |                            |  default  |  ...targetgroup/usms-enrolment |
+----------------+----------+----------------------------+-----------+--------------------------------+
describe-target-health usms-results-tg  -> []
attached load balancers                  -> 1
/results (from usms-web-01)              -> 503
```

There are three entries in evaluation order, the results target group is empty and attached to one load balancer, and neither object was recorded in `configs/lab-05.env`.

**What `/results` receives with no targets:** the listener matches the priority-20 rule and forwards to a target group with no healthy targets, so the load balancer itself answers **`503 Service Temporarily Unavailable`**. On this build, that was observed, not reasoned about.

---

## Exercise 2 - Intermediate: repair the verification script you broke

**1. The property** the failing check asserted: *the enrolment tasks accept traffic only from one named security group, never from a CIDR range.* "That group is `usms-app-sg`" was only the value that property happened to have in Lab 04.

**2-4. The change** (`scripts/utilities/verify-lab-04.sh`):

- The script now sources `configs/lab-05.env` optionally (`2>/dev/null || true`).
- If that file exists, the expected sole source is `${USMS_ALB_SG:-none}`. If it is absent (a Lab 04-only checkout), the expected source is `usms-app-sg`.
- The rewritten check compares the **whole sorted set** of source groups with that one expected group and requires that there are no CIDRs. It no longer reads `UserIdGroupPairs[0]`, which became order-dependent once two sources could exist.
- A new check immediately after it asserts that `usms-app-sg` is **no longer** a source (in Lab 04-only mode, that there is exactly one source group). A check that only confirmed the new source would still pass with both rules present.
- Under `set -u`, a missing `USMS_ALB_SG` becomes the expected value `none`, which gives a readable failed check rather than an unbound-variable abort.
- The original check was rewritten, not deleted, and `${BASH_SOURCE[0]}` resolution is unchanged.
- The header comment now states `Expected: PASS=39 FAIL=0`.

**5. Results**

```text
verify-lab-04.sh  PASS=39  FAIL=0
   ok   usms-enrolment-sg is sourced only from usms-alb-sg (Lab 05 cutover), by group not CIDR
   ok   usms-app-sg is NO LONGER a source of usms-enrolment-sg
negative test - configs/lab-05.env moved away (Lab 04-only checkout): readable FAIL, PASS=38 FAIL=1, no abort
negative test - lab-05.env present without USMS_ALB_SG:               readable FAIL, PASS=38 FAIL=1, no abort
verify-lab-05.sh  PASS=47  FAIL=2   (both from Floci not storing healthCheckGracePeriodSeconds - see notes)
```

**Why the count is documented:** a stated `PASS=39` turns "it printed some oks" into a checkable claim. If a check silently stops running (a typo in `check`, a deleted line, a function that returns early), an undocumented count lets the suite *shrink* without anyone noticing, which is worse than having no count, because it looks like assurance.

**When updating a verification script is right, and when it hides a regression:** updating is right when the system's *intended* architecture changed, deliberately and reviewably, and the check is rewritten to assert the same property against the new design in the same commit. It hides a regression when a check is edited (or loosened, or deleted) simply because it went red, without a decision that the old behaviour was supposed to change. The script then agrees with whatever the system currently does, which is exactly what a verification script must not do.

**6. Commit message** (to be used when Lab 05 is committed):

```text
verify-lab-04: assert the enrolment tasks' single source group, not usms-app-sg

Lab 05's cutover made the load balancer the only caller of the enrolment tasks,
so "sourced from usms-app-sg" encoded an architecture that no longer exists.
The check now asserts the underlying property - exactly one source GROUP, no
CIDR - against usms-alb-sg when configs/lab-05.env exists (usms-app-sg for a
Lab 04-only checkout), and a new check proves the web tier is no longer a source.
Expected count is now PASS=39.
```

---

## Exercise 3 - Problem solving: a load balancer report tool

Script: `scripts/utilities/usms-lb-report.sh`.

- Bash resolves `configs/` from `${BASH_SOURCE[0]}` and sources `course.env`, then hands the four-level walk to `python3`: load balancers whose name starts with `usms-`, then listeners sorted by port, then rules, then target health.
- `Priority` is a string, and the default rule's is `"default"`. The rules are sorted numerically, so `"5"` precedes `"10"` (a plain string sort would get that wrong), with the default last, because it runs only when nothing matched. The comment in `prio_key()` explains this.
- Non-forward actions print their own summary (`fixed-response 200`, `redirect 301 -> …`).
- A load balancer with no listeners prints `(no listeners - this load balancer answers nothing)`. An empty target group prints `(0 targets, 0 healthy)`. No row is ever blank.
- `set -uo pipefail` without `-e`, justified in a comment.
- It writes `outputs/lab-05-lb-report.json`.

**Identical from `~` and from `labs/lab-05-ecs-alb/`:**

```text
usms-enrolment-alb   internet-facing  application  active  AZs=2  SGs=1
  HTTP:80
    prio  10       path-pattern  /alb-health,/alb-health/*   -> fixed-response 200
    prio  20       path-pattern  /results,/results/*         -> usms-results-tg  (0 targets, 0 healthy)
    prio  default  -             -                           -> usms-enrolment-tg  (2 targets, 2 healthy)
```

**Edge case - a listener with no non-default rules.** Instead of deleting the `/alb-health` rule (a KEEP object, which would come back with a new ARN), a temporary `HTTP:8080` listener with only a default `fixed-response` was added, reported on, and deleted. This exercises the same code path:

```text
  HTTP:8080
    prio  default  -             -                           -> fixed-response 503
temporary listener deleted
```

After Exercise 4's tidy-up, the report correctly shows only priority 10 and the default.

---

## Exercise 4 - Challenge: the exposure review

*To: Information Security Officer. Re: the student enrolment API.*

### What changed (two sentences)

**Network path:** the enrolment tasks used to be reachable only by an address inside the VPC, from the web server. They are now reached through an internet-facing Application Load Balancer in the two public subnets, which forwards to the tasks' private addresses. **Security groups:** the tasks' group used to admit HTTP from the web tier's group (`usms-app-sg`); it now admits HTTP **only** from the load balancer's group (`usms-alb-sg`), and the load balancer's group admits HTTP from anywhere on the internet.

### Internal versus internet-facing

**The case for `--scheme internal`:**

- Step 5's command would change only in `--scheme internal`, and the subnets could then be the *private* subnets.
- The DNS name would be prefixed `internal-…` and resolve to **private** IP addresses only. From the internet it would resolve, but nothing could connect.
- `usms-alb-sg` would admit tcp/80 from `usms-app-sg` instead of `0.0.0.0/0`.
- Nothing else changes: the listener, rules, target group, service attachment and task security group are identical.
- Since the student portal (`usms-web-01`) is the **only** client of this API, I recommend **internal**. It removes the only `0.0.0.0/0` ingress rule in the course and makes the enrolment API unreachable from the internet by construction.
- The scheme cannot be changed after creation, so this means creating a new load balancer, repointing the service's target group, and deleting the old one.

**The other side:** an internet-facing load balancer is needed the moment any client other than the portal calls the API directly (a mobile app, a partner system, or browser JavaScript calling the API from students' devices). It is also the natural place to attach CloudFront and AWS WAF, so if direct client access is on the roadmap, building it public now, *with* HTTPS and WAF, avoids a second migration.

### The exposure delta

| Who can reach… | Before (Lab 04) | After (Lab 05) |
|---|---|---|
| **The load balancer** | Did not exist | **Anyone on the internet**, tcp/80 (and 443 is opened in its security group, though nothing listens there yet) |
| **The tasks** (any path) | Only `usms-app-sg` members (`usms-web-01`, `usms-web-02`) | Only through the load balancer: `usms-alb-sg` is the sole source |
| **The tasks *directly*, by private IP** | The web tier, by address | **Nothing.** The web tier's direct rule was removed (Step 13); the tasks still have no public IP |

What could reach them before and now cannot: the web servers, by address. What can reach them now that could not before: anyone on the internet, *indirectly*, through the load balancer's listener and rules.

### Monthly cost estimate (us-east-1)

Sources: **Elastic Load Balancing pricing** (aws.amazon.com/elasticloadbalancing/pricing/): ALB **USD 0.0225 per hour** and **USD 0.008 per LCU-hour**. **Amazon VPC pricing** (aws.amazon.com/vpc/pricing/): **USD 0.005 per public IPv4 address per hour**. **AWS Fargate pricing** (aws.amazon.com/fargate/pricing/): USD 0.04048 per vCPU-hour and USD 0.004445 per GB-hour, as in Lab 04. *Re-check the live pages before quoting.*

An LCU is billed on the **largest** of four dimensions per hour: 25 new connections/s, 3,000 active connections/min, 1 GB processed per hour (EC2/IP targets), and 1,000 rule evaluations/s. For a low-traffic JSON API, the dominant dimension is **new connections per second**, not processed bytes (which most people guess). Each enrolment call is small (well under 1 KB), but if clients do not reuse connections, every call is a new connection. 180 req/s at the Monday peak is 180 ÷ 25 = **7.2 LCU**, against only about 0.6 GB/hour of bytes at 1 KB each.

| Item | Derivation | USD / month |
|---|---|---|
| ALB hours | 730 h × 0.0225 | 16.43 |
| ALB public IPv4 (one per AZ node, 2 AZs) | 2 × 730 h × 0.005 | 7.30 |
| LCUs, **idle** | Under 1 new connection/s, about 0.04 LCU average × 730 × 0.008 | ≈ 0.23 |
| LCUs, **under load** | Enrolment week: 20 min/week at 7.2 LCU = 2.4 LCU-h; rest of month at about 0.2 LCU = 146 LCU-h; ≈ 150 LCU-h × 0.008 | ≈ 1.20 |
| **ALB total** | **idle ≈ 23.96; under load ≈ 24.93** | |
| For comparison: the two Fargate tasks | 2 × 730 × (0.25 × 0.04048 + 0.5 × 0.004445) | 18.02 |

The load balancer costs more than the service it fronts, and it costs about USD 24 a month **even if nobody calls it**. An internal ALB costs the same hourly rate but needs no public IPv4 addresses (saving 7.30).

### The HTTPS plan

**What makes 443 *open*:** the security group rule. That is already done (Step 4 "Your turn": tcp/443 from `0.0.0.0/0` on `usms-alb-sg`).

**What makes something *listen* on 443:**

1. **A domain name** the university controls, for example `enrolment.usms.edu`. This comes from **outside AWS** (the university's DNS / registrar), or from Route 53 domain registration, which is paid.
2. **An ACM public certificate** for that name: `aws acm request-certificate --domain-name enrolment.usms.edu --validation-method DNS`. **Free**: public ACM certificates for use with ELB carry no charge, and they renew automatically. (AWS Certificate Manager User Guide, "Requesting a public certificate".)
3. **DNS validation**: create the CNAME record ACM returns, in the university's DNS zone. This is again *outside* AWS unless the zone is hosted in Route 53. The certificate then becomes `ISSUED`.
4. **An HTTPS listener**: `aws elbv2 create-listener --protocol HTTPS --port 443 --certificates CertificateArn=<acm-arn> --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 --default-actions …forward to usms-enrolment-tg`. Re-create the `/alb-health` rule on it. (Elastic Load Balancing User Guide, "Create an HTTPS listener for your Application Load Balancer".)
5. **A DNS record** `enrolment.usms.edu` → ALIAS/CNAME to the load balancer's DNS name, so the certificate's name matches what clients type.
6. **The port-80 change:** modify the HTTP:80 listener's **default action** to type **`redirect`**, with `Protocol=HTTPS, Port=443, StatusCode=HTTP_301`, so nothing is ever served in plaintext. (Elastic Load Balancing User Guide, "Listener rules - redirect actions".)

What AWS provides free: the certificate, its renewal, and TLS termination on the load balancer (which you pay for as normal ALB hours and LCUs). What needs something outside AWS: the domain name and the DNS validation record.

### The tidy-up

> [!CAUTION]
> **What will be deleted:** the priority-20 listener rule (`/results`, `/results/*` → `usms-results-tg`) from Exercise 1.
> **What depends on it:** nothing. It forwards to an empty target group, and no configs file records it. The `/alb-health` rule (priority 10, KEEP) is untouched.
> **Reversible?** Yes, with Exercise 1's `create-rule` command (it would get a new ARN).
> **Effect on later labs:** none. It must go first: `delete-target-group` fails with `ResourceInUseException` while a rule forwards to the target group.

```bash
R20=$(aws elbv2 describe-rules --listener-arn "$USMS_ALB_LISTENER_ARN" \
  --query "Rules[?Priority=='20'].RuleArn | [0]" --output text)
aws elbv2 delete-rule --rule-arn "$R20"
```

> [!CAUTION]
> **What will be deleted:** the target group `usms-results-tg` from Exercise 1.
> **What depends on it:** nothing, once the priority-20 rule is gone. It holds no targets and is not in `configs/lab-05.env`.
> **Reversible?** Yes, with Exercise 1's `create-target-group` command (new ARN).
> **Effect on later labs:** none. Lab 06 names `usms-enrolment-tg`, not this one.

```bash
RTG=$(aws elbv2 describe-target-groups --names usms-results-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 delete-target-group --target-group-arn "$RTG"
```

**Executed:**

```text
deleted priority-20 rule
deleted usms-results-tg
describe-rules            -> 10 fixed-response / default forward
describe-target-groups    -> TargetGroupNotFound: usms-results-tg
verify-lab-05.sh          -> PASS=47 FAIL=2  (the two documented grace-period failures only)
```

Nothing in Section 15's KEEP column was touched, in particular not the `/alb-health` rule.

---

## Exercise 5 - Integration: the ResourceLabel hand-off to Lab 06

**1. `scripts/utilities/usms-resource-label.sh`**

- Arguments default to `usms-enrolment-alb` and `usms-enrolment-tg`.
- It looks both ARNs up **from the API**, never from `configs/lab-05.env`, and cuts them with shell parameter expansion:
  - The load balancer suffix `${LB_ARN#*:loadbalancer/}` **drops** its `loadbalancer/` resource type.
  - The target group suffix `${TG_ARN##*:}` **keeps** `targetgroup/…`, because it is everything after the ARN's last colon.
- It validates the result before printing: six segments, `app` first, `targetgroup` fourth, both names present. A bad name exits non-zero instead of printing a guess.

```text
$ (from ~) usms-resource-label.sh
app/usms-enrolment-alb/59dc0d3ea7324f5e/targetgroup/usms-enrolment-tg/add5ea39cc5b477f
$ usms-resource-label.sh usms-enrolment-alb no-such-tg
exit=254
```

**2.** `USMS_ALB_RESOURCE_LABEL` was appended to `configs/lab-05.env`, derived by the script. The file now has **16** exports.

**3. Readiness file:** `outputs/lab-05-lab04c-readiness.txt` (committed copy: `labs/lab-05-ecs-alb/lab06-readiness.txt`). It records the resource label, the target group ARN, the load balancer ARN, `service/usms-ecs-cluster/usms-enrolment-svc`, `ecs:service:DesiredCount`, desired count `2`, and the recommendation: `ALBRequestCountPerTarget`, because it measures demand for a request/response API directly, while CPU lags.

**4. The measurement** (timestamps from `python3`):

| Measurement | Result |
|---|---|
| Forced deployment, until one deployment and a stable target list | 11.5 s, but **meaningless**: Floci replaced no task (identical task ARNs before and after) |
| **Capacity add:** `update-service --desired-count 3` until the third target is `healthy` through the ALB's own health checks | **38.5 s** |
| AWS's documented figure for Fargate | 20 to 60 s to reach `RUNNING`, plus up to interval × healthy threshold (30 s × 2) before a new target receives traffic |

38.5 s sits inside AWS's range, so a scale-out cooldown of about 60 s is consistent with this environment, and a longer scale-in cooldown (300 s) avoids removing capacity mid-burst.

**5. Label checks:** it contains both names, has **6** slash-separated segments, and its first segment is **`app`**. `app` is the load balancer *type* embedded in its ARN (`loadbalancer/app/…`). For a Network Load Balancer it would be `net`, and NLBs have no `ALBRequestCountPerTarget` metric.
