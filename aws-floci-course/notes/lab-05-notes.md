# Lab 05 Notes

## Support path (Step 3): **Path A - full**

Every probe answered. More importantly, Floci 1.7.0 ran a **real ELBv2 data plane**: Floci's log showed `ELBv2 listener port started on 80`. Inside the course's Docker network, the load balancer's name `usms-enrolment-alb-59dc0d3ea7324f5e.elb.floci` resolves to Floci's listener (`172.19.0.2`), so `usms-web-01`, the actual client in this architecture, received a genuine response.

| Observed on this build | Only reasoned about |
|---|---|
| Every object (ALB, target group, listener, rule, both security groups) and its read-back | Load balancer nodes per AZ with public addresses; public DNS resolution |
| `HTTP 200` from `usms-web-01` → ALB → nginx task, before and after the cutover and after a restart | `X-Forwarded-For`, cross-zone balancing, idle timeout enforcement |
| Real health checks: targets went `initial` (`Elb.InitialHealthChecking`) → `healthy` | `unhealthy` and its `Reason` field (nothing ever failed) |
| The service registering and deregistering its own targets (2 → 3 → 2) | `draining` and the 30 s deregistration delay (never observed; targets vanished at once) |
| Rule evaluation: `/alb-health` → fixed 200 (22 bytes) while `/` → nginx; `/alb-healthcheck-internal` not matched | A rolling deployment (Floci never replaced tasks on `--force-new-deployment`) |
| `/results` → `503` from a rule whose target group was empty (Exercise 1) | HTTPS, ACM, `AWS/ApplicationELB` metrics, cost, quotas, security-group enforcement |
| Configuration persistence across a Floci restart | |

## Step 4 "Your turn": 443 is open, but nothing listens on it

`usms-alb-sg` now admits tcp/443 from `0.0.0.0/0`, but that only **opens** the port. Two things are still missing: an **HTTPS listener** on 443 (which is what makes the load balancer *listen*), and a **TLS certificate** for that listener to present. AWS gives you the certificate for free through ACM (public ACM certificates cost nothing). What you have to obtain from somewhere else is a **domain name you control**, because ACM validates ownership by a DNS record and the ALB's `…elb.amazonaws.com` name can never be on your certificate.

## Step 6 "Your turn": the matcher

(a) An application whose root path redirects, such as a web app that sends `/` to `/login` with a `302`, would be reported unhealthy forever by a strict `200` matcher, even though it is working perfectly.
(b) It would be a bug in my work, not in the script: a verification script records the configuration the lab *decided on*, so a difference from it is drift by definition. If `200-399` were the right choice, the fix would be to change the decision and the script together, in the same commit.

## Step 11: two opinions of one task's health (Review Question 4, assessment Task C)

| ECS `healthStatus` | Target health | Diagnosis |
|---|---|---|
| `HEALTHY` | `healthy` | Working |
| `HEALTHY` | `unhealthy` | **The network path is broken.** Security group, subnet, or the health check path returning the wrong code |
| `UNHEALTHY` | `unhealthy` | The application is broken. Read the container logs |
| `UNKNOWN` | `healthy` | Not a fault. The task definition has no container health check |
| anything | `unused` | Nothing forwards to this target group |

On this build ECS reported no `healthStatus` (`None`, the equivalent of `UNKNOWN`) while both targets were `healthy`: the "not a fault" row, because `usms-enrolment` has no container health check.

**Step 11 "Your turn":** if the service did not register its own targets, then after every single scaling event I would have had to run `register-targets` (and `deregister-targets` on scale-in) with the new tasks' private IP addresses, by hand.

## Floci limitations hit in this lab (Floci 1.7.0)

| What happened on Floci | What real AWS would have done |
|---|---|
| `update-service --load-balancers … --health-check-grace-period-seconds 60` returned success but stored **nothing** (`loadBalancers: null`). I took the lab's documented fallback and recreated the service with the same name, cluster, task definition (`usms-enrolment:2`) and desired count, with the load balancer attached; the ARN was unchanged. The fallback's `--deployment-configuration file://templates/lab-04-deployment-config.json` was omitted because my Lab 04 never created that file (defaults 100%/200% apply) | In-place update supported for the `ECS` deployment controller; triggers a rolling replacement |
| `healthCheckGracePeriodSeconds` is never stored, on `create-service` or `update-service`. `verify-lab-05.sh` therefore reports **two** failures from this one cause: the grace check (benign per the lab's table) and the env-file `None` check that follows from it | Stored and enforced: ECS ignores target health for the first 60 s of each task |
| `revoke-security-group-ingress --security-group-rule-ids sgr-ea24…` returned `True` and removed **nothing**. Revoking by `--ip-permissions file://policies/usms-enrolment-sg-ingress.json` worked, but `describe-security-group-rules` still lists the revoked rule, so Floci's two views of the group disagree | Revoke by rule ID works; both APIs agree |
| `authorize-security-group-ingress` with a second source group created a **separate** `IpPermission` instead of merging both sources into one | One `IpPermission` with two `UserIdGroupPairs` (the lab's Step 9 expected output) |
| `--force-new-deployment` (Step 14 and Exercise 5) replaced no task: identical task ARNs and target addresses before and after, so `initial` → `healthy` → `draining` during a deployment was not observable | A rolling replacement; old targets show `draining` for up to `deregistration_delay` |
| On scale-in the removed target vanished immediately, with no `draining` state | `draining` for up to 30 s |
| After the Floci restart, the two original tasks' containers kept running but ECS stopped tracking them, launched two replacements, and left **four** targets registered for a desired count of 2. I deregistered the two orphaned addresses and removed their containers (`outputs/lab-05-step16-orphans.txt`); the service-owned targets were never touched | Impossible: ECS deregisters every task it stops |
| After the restart, `usms-db-02` (Lab 03 Exercise 2) came back `stopped`; it was left stopped deliberately, because restarting instances after a Floci restart hit the SSH port-collision bug in Lab 03 | Instances are unaffected by the operator's laptop |
| Target addresses are Docker bridge IPs (`172.19.0.x`), so Step 12's subnet check prints "NOT in a Lab 02 private subnet" | Addresses in `10.0.3.0/24` and `10.0.4.0/24`, one per AZ |
| `Target.AvailabilityZone` is `None` | Each `ip` target reports its AZ |
| `describe-target-group-attributes` returns only the two attributes I set (no `stickiness.enabled`, `slow_start…`) | The full attribute list |
| `SslPolicy` returned as `""` on an HTTP listener | `null` |
| The DNS name is `…elb.floci`, resolvable only inside the Docker network | Public DNS resolving to the nodes |
| `instance.group-id` filter ignored (as in Lab 04) | Honoured |

**Two bugs in the lab text itself:**

- Step 14's polling loop uses `--query 'length(deployments)'`, which errors on every poll and never breaks. The correct form is `length(services[0].deployments)`.
- Step 18's `` \` `` escaping keeps its backslash inside `$( '…' )` in an unquoted heredoc, in both bash and zsh (tested), so `USMS_ALB_LISTENER_ARN` came out empty. I used the backtick-free `Listeners[?to_string(Port)=='80']` instead.

**Script fix:** as in Lab 04, `verify-lab-05.sh`'s check `no secret is tracked by git` flagged the required `outputs/.gitkeep`. I excluded only that file.

## Review Questions

### 1. Group references and load balancers solve the same problem

Both decouple *who* from *where*. Lab 04's rule names `usms-app-sg` instead of an address range, because the web tier's addresses are not stable or known in advance. This lab's load balancer gives the enrolment service a stable name, because the tasks' addresses change on every deployment, scale-out and restart (I watched them change from `172.19.0.6/.7` to `.5/.8` across the restart). The general problem is **indirection for ephemeral endpoints**: clients and rules should refer to a stable identity, and the system maps that identity to whatever the current members happen to be. A third solution elsewhere in computing is **DNS** itself, which maps a stable hostname to changing IP addresses. Service discovery registries (Consul, Kubernetes Services, AWS Cloud Map) and virtual IPs in front of a database cluster are the same idea.

### 2. "Unhealthy target, so the application is broken" is unsound

The load balancer's health check only reports whether a probe *from the load balancer, over the network, to that port and path* got the expected response. A target can fail that probe because the application is broken, **or** because the path to a perfectly working application is broken: the security group does not admit the load balancer, the port is wrong, or the health check path returns a redirect that the matcher rejects. The target group's `State` cannot distinguish "application down" from "network path blocked". Both are simply `unhealthy`. The field that does distinguish them is `TargetHealth.Reason` (with `Description`): `Target.Timeout` means nothing answered (security group or port), and `Target.FailedHealthChecks` / `Target.ResponseCodeMismatch` means something answered wrongly (application or matcher). The diagnostic sequence is:

1. Read `Reason`.
2. Compare it with ECS's own view of the task (`healthStatus`, `lastStatus`, `stoppedReason`), using the side-by-side table above.
3. If ECS says healthy, check the security group, then the port, then the path and matcher.
4. Only then read the application's logs.

### 3. Configuration versus identity

There is no `update-target-group-target-type` because a target group's target type (like its VPC and its protocol/port binding to targets) is part of its **identity**: what kind of thing it holds and where. Changing it would mean every registered target became meaningless, so AWS makes you create a different target group. Health check settings, the matcher and attributes like the deregistration delay are **configuration**, editable in place (`modify-target-group`, `modify-target-group-attributes`). This mirrors Lab 04's immutable task definition revisions: you never edit `usms-enrolment:1`, you register `:2` and repoint the service. Two other identity-like fields in this lab are a load balancer's **`Scheme`** (internet-facing / internal) and its **`Type`** (application / network), both fixed at creation. One that looks as if it should be fixed but is not: the load balancer's **security groups**, which can be replaced at any time with `set-security-groups`. Its **subnets** can be changed too, with `set-subnets`.

### 4. A request at the moment its task is stopped

The timers, in order:

- ECS decides to stop task T and first **deregisters** it from `usms-enrolment-tg`.
- The load balancer marks T `draining`: it stops sending new requests to T but lets in-flight ones finish, for at most **`deregistration_delay.timeout_seconds`** (30 s, on the target group, Step 7).
- ECS then sends `SIGTERM`, waits the task definition's **`stopTimeout`** (default 30 s), and sends `SIGKILL`.
- The load balancer's **`idle_timeout.timeout_seconds`** (60 s, on the load balancer, Step 5) bounds how long an idle connection stays open.
- The service's **`minimumHealthyPercent`** decides whether replacement capacity exists first.
- The **health check interval × thresholds** (30 s × 2) decide when a replacement is allowed to receive traffic.

A request that was *already in flight* to T succeeds, provided it finishes within the 30 s drain. A request *arriving* at that moment is routed to another healthy target, because T no longer receives new requests, so it also succeeds. If the deregistration delay were left at 300 s, nothing would be lost, but every deployment and every scale-in would stall for up to five minutes per task waiting on connections a millisecond API never holds. Deployments would be roughly ten times slower, and scale-in would pay for idle tasks the whole time.

### 5. Update Lab 04's script now, or leave it failing?

*Update it now:* a verification script that is known to fail trains everyone to ignore red. The next real regression in `verify-lab-04.sh` will be hidden behind the "expected" failure. The right moment to change an assertion is in the same commit as the architectural change that invalidated it, while the reason is fresh. *Leave it failing and documented:* the script is a record of what Lab 04 built and asserted. Silently editing it to green rewrites history and can mask the fact that the old property (web tier reaches tasks directly) was deliberately removed. A visible, explained failure communicates the change. With **four other engineers** I would update it immediately (as Exercise 2 did), asserting the *property* rather than the old value, with a commit message explaining the cutover, because a shared red check costs everyone attention and erodes trust in the whole suite. **One** engineer could reasonably leave it documented for a while, because the only person who needs to understand the failure is the one who caused it.

### 6. Internet-facing load balancer, private tasks

Both are true because the load balancer and the tasks live in different subnets with different routes:

- The ALB's nodes sit in `usms-public-subnet-a` and `-b`, whose route table `usms-public-rt` has `0.0.0.0/0 → usms-igw`, attached to `usms-vpc`. That is what makes them reachable from the internet, and `usms-alb-sg` admits tcp/80 from `0.0.0.0/0`.
- The tasks sit in `usms-private-subnet-a` and `-b`, whose route table `usms-private-rt` sends `0.0.0.0/0 → usms-nat` (outbound only), with `assignPublicIp DISABLED`. They have no public address and no inbound route from the internet at all.
- The ALB **terminates** each client connection and opens a new one to a task's private IP inside the VPC (the `local` route), and `usms-enrolment-sg` admits only `usms-alb-sg`.

An attacker who compromised the load balancer's *configuration* could repoint listeners and rules: forward traffic to any target group or private IP in the VPC that the ALB's security group can reach, return fixed responses, or redirect users elsewhere. They still could not open a connection to a task from the internet directly. Had the tasks had public addresses, the tasks' only protection would be `usms-enrolment-sg`: one mistaken rule (say, `0.0.0.0/0` on 80) would expose them directly, bypassing the load balancer, its rules and any future WAF. With private tasks, routing makes that impossible regardless of the security group.

### 7. Requests per target versus CPU

For a web API, **requests per target** measures demand directly and *before* it hurts. Each task can serve roughly a known number of requests, so scaling to keep requests-per-task at a target adds capacity as traffic arrives. CPU is an indirect, lagging symptom that only rises once tasks are already busy, and it varies with request mix and runtime. CPU is the better signal when work is **CPU-bound and not proportional to request count**, for example a queue worker or batch processor with no load balancer in front, or an endpoint where a few requests trigger heavy computation (report generation, PDF rendering). `ALBRequestCountPerTarget` would scale the enrolment service badly if requests were **wildly unequal in cost** (a cheap health or list call next to an expensive registration transaction). It would also scale badly if the bottleneck were **downstream**, such as a database or third-party API where adding tasks cannot help and only adds more load. A final bad case is clients using long-lived connections (WebSockets), where few requests represent heavy, sustained work.
