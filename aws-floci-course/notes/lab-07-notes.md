# Lab 07 Notes

## Lab 07 support path
Probed on 2026-10-16T03:09:49Z
PATH A  - use aws eks throughout

`aws eks create-cluster` started a **real k3s cluster** in a container (`floci-floci-course-eks-usms-eks-cluster`, image `rancher/k3s:latest`) and reported `ACTIVE` within about 30 seconds. `aws eks update-kubeconfig` worked, including the `aws eks get-token` exec plugin, so the certificate-kubeconfig fallback was not needed. `k3d` is not installed and was not needed. What Path A means on this build:

- **The Kubernetes half is real:** API server, scheduler, CoreDNS, kube-proxy, metrics-server, rolling updates, probes, the eviction API.
- **The AWS half is records:** the cluster, node group, roles and tag are stored and returned, and only the cluster record drives anything (it starts the k3s container).
- **One node, not two, as Floci built it:** the cluster runs a single k3s server node (`control-plane`, no taint, so pods schedule on it). The node group `usms-eks-nodes` is `ACTIVE` but adds no node. **Repaired afterwards** (see "Repairs after the lab"): `scripts/utilities/eks-nodes-join.sh` joins the node group's `desiredSize` (2) k3s agents, `usms-eks-node-1` and `-2`, labelled `workload=usms tier=app eks.amazonaws.com/nodegroup=usms-eks-nodes` from the node group record, so the cluster now has 3 nodes.
- **Kubernetes v1.34.1+k3s1**, although `describe-cluster` says `1.30`. The API server listens on **`https://localhost:6500`**, not 6443.

## Step 3 "Your turn": is EKS just ECS with different names?

**False because of the data plane column.** On EKS I own and patch the nodes the pods run on (the node group, its AMI, the kubelet, the CNI), and upgrading is two operations, control plane and then node group. On ECS with Fargate there is no node for me to see at all. EKS also has its own API (Kubernetes) beside the AWS one, with its own objects, its own authorisation and its own client, `kubectl`.

**Nearly true because the control-plane jobs map one to one.** Both keep N copies of a container spec alive and replace failures, roll a new version out gradually, and give the copies one stable name to be found by. A task definition is roughly a pod template, an ECS service is roughly a Deployment plus a Service, and the cluster is just a scope in both.

## Step 8: session name

`sts assume-role --role-session-name lab05a-eks-build` returned `assumed-role/usms-developer-role/floci-session`: Floci ignores the session name. The cluster was still created while holding the developer role's credentials, and `whoami.sh` showed `root` again after the `unset`.

## Step 9: `_lb_ports_` and the "Your turn" (version and OIDC issuer)

`cluster.tags._lb_ports_` printed `8081,8082` first time; no `tag-resource` was needed. **However, the k3s container publishes only `6443/tcp -> 6500`**, not 8081 or 8082 (`docker inspect … PortBindings`), and k3s was started with `--disable=traefik`. The tag alone did not publish them. **Repaired afterwards:** a LoadBalancer Service *is* served by k3s's built-in klipper load balancer on the node's own address (`172.19.0.6:8081` answered from the host), so a small forwarder container, `usms-eks-lbfwd`, publishes `127.0.0.1:8081-8082` to the k3s container by name. `curl localhost:8081/` then reached a test LoadBalancer Service (`outputs/lab-07-repair-lbports.txt`).

```bash
aws eks describe-cluster --name usms-eks-cluster --query 'cluster.[version,identity.oidc.issuer]' --output text
1.30	https://oidc.eks.us-east-1.amazonaws.com/id/86B308CD739044B294399CDB992A946F
```

The **OIDC issuer** is the URL of the cluster's OpenID Connect discovery document. IAM trusts tokens signed by the keys published there, which is how IRSA lets a pod's ServiceAccount token be exchanged for IAM credentials. This build returned a URL, not `None` (see Step 21 for why it still does not work).

## Step 10: the node group is a record

`usms-eks-nodes` is `ACTIVE` in exactly the two private subnets (`subnet-bbcb26d3`, `subnet-0d751e14`), min 2 / max 4 / desired 2, role `usms-eks-node-role`, labels `workload=usms tier=app`, AMI type `AL2023_x86_64_STANDARD`. It became `ACTIVE` in the `create-nodegroup` response itself, and no container appeared: **`t3.small` is recorded but nothing is provisioned**, and `kubectl get nodes` still showed one node until the repair below joined two agent nodes.

## Step 16 "Your turn": who replaced the deleted pod

The replacement was created by the **ReplicaSet** `usms-enrolment-6965b8dbbb`: the event is `SuccessfulCreate replicaset/usms-enrolment-6965b8dbbb Created pod: usms-enrolment-6965b8dbbb-vxfzv`. The Deployment only manages ReplicaSets; the ReplicaSet keeps its pod count. 20 of 20 requests through `/enrolment/` succeeded straight after the delete, and the new pod answered 14 of them.

## Step 17: the Secret file, and what `set env` actually wrote

- I kept `manifests/lab-07/50-secret.yaml` in the repository **deliberately**, because both values are labelled dummies and the lab uses it in Step 24. In any real repository I would generate it into `outputs/` or use a secrets manager and never commit a base64 value.
- `kubectl set env --from=secret/…` (client v1.36) did **not** add an `envFrom.secretRef` as the lab text says. It added two `env` entries with `valueFrom.secretKeyRef`, one per key, so the lab's `jsonpath='{…envFrom}'` check shows only `usms-app-config`. `describe` lists the secret per variable instead. The effect is the same: four `APP_*` and two `ENROLMENT_*` variables in the container, the token in plain text.

## Step 18: rollback, and what it did not revert

The revision numbers differ from Checkpoint 6 because Step 17's `set env` was itself revision 2:

| Revision | ReplicaSet | Cause |
|---|---|---|
| 1 | `6965b8dbbb` | Step 13 create |
| 2 | `7d8557c58d` | Step 17 `set env --from=secret` |
| (none) | | `kubectl annotate` changed the Deployment's own metadata, not the pod template, and **did not roll** (`rollout status` returned in 0.7 s) |
| 3 | `74cb96b9cf` | `rollout restart`: the pod answered `1.1.0` |
| 4 | `7d8557c58d` again | `rollout undo` scaled revision 2's ReplicaSet back up: the same hash, renumbered |
| 5 | `6bfc765b85` | `rollout restart` after restoring the ConfigMap to `1.0.0` |

**What undo did not revert:** after `rollout undo` the pod still answered `"version":"1.1.0"`, because undo restores the *pod template*, and the version lives in the ConfigMap, which undo never touches. The new pods simply read the current ConfigMap at start-up.

## Step 18 "Your turn": an image roll of `usms-results`

`kubectl set image deployment/usms-results results=nginx:1.27` then `kubectl rollout undo --to-revision=1`. Afterwards `rollout history` lists **two revisions (2 and 3)**, and the Deployment is back on `nginx:1.27-alpine` at 2/2.

Sampling the pods four times a second, the peak was **3 live pods (2 old + 1 new)**, plus one old pod briefly shown `Completed` while terminating. The roll never dropped below 2 ready. **It did not differ from `usms-enrolment`'s shape**, and that is the finding: with 2 replicas the default 25% / 25% resolves to maxSurge = ceil(0.5) = **1** and maxUnavailable = floor(0.5) = **0**, which is exactly enrolment's explicit 0 / +1. The difference only appears at 4 or more replicas, where 25% unavailable becomes a whole pod.

## Step 20: ECS and Kubernetes, compared with both running

Both were captured side by side (`outputs/lab-07-step20.txt`): ECS `usms-enrolment-svc` desired 2, running 2, `usms-enrolment:2`, 1 load balancer, 1 deployment; EKS three Deployments 2/2, 1/1, 2/2 with three ClusterIP Services.

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | The task definition revision (`usms-enrolment:2`), immutable and numbered | The Deployment's pod template (`spec.template`), edited in place; each change is captured in a new ReplicaSet |
| What keeps N copies alive? | The ECS service scheduler, reconciling `runningCount` to `desiredCount` | The ReplicaSet controller, reconciling pods to `replicas` |
| What gives it a stable name? | The service name, plus the ALB DNS name in front of it (Lab 05) | The Service object: a ClusterIP and a DNS record `usms-enrolment.usms.svc.cluster.local` |
| How does another service find it? | Through the load balancer, or Cloud Map service discovery; nothing is automatic | By DNS name through CoreDNS, automatically for every Service; kube-proxy spreads the traffic |
| What does a rolling update create? | A new *deployment* inside the service, starting tasks of the new task definition revision | A new ReplicaSet, scaled up while the old one is scaled down |
| Where does rollback state live? | In the old task definition revisions; rolling back is another `update-service` to the earlier revision | In the old ReplicaSets kept at 0 replicas (up to `revisionHistoryLimit`); `rollout undo` scales one back up |
| Which IAM role does the app code use? | The task role (`usms-ecs-task-role`), per task | Here the node role (`usms-eks-node-role`), shared by every pod on the node; properly, an IRSA role per ServiceAccount |
| What would I have to change to move to another cloud? | Almost everything: task definitions, services, ECS-specific IAM and the ALB wiring are all AWS-only | The manifests move unchanged, but the IAM roles, VPC and subnets, node group, load balancer annotations and IRSA do not |

**For USMS I would choose ECS (on Fargate).** A small team with a quiet eight months gets no node patching, no second API and no cluster to keep healthy, and Labs 05 and 06 already give it the load balancer and scaling it needs. Kubernetes would be worth its cost only if USMS grew to many services or had to be portable across clouds.

## Step 21: IRSA, and which of the six steps completed

| # | IRSA step | On this build |
|---|---|---|
| 1 | The cluster publishes an OIDC discovery document | **Partly.** `describe-cluster` returns an issuer (`https://oidc.eks.us-east-1.amazonaws.com/id/DB7E4CB9…` after the recovery), but that URL returns **HTTP 404** from AWS's real OIDC host, and k3s actually signs ServiceAccount tokens as `https://kubernetes.default.svc.cluster.local` (`kubectl get --raw /.well-known/openid-configuration`) |
| 2 | Register it in IAM as an OIDC provider | **Done.** `create-open-id-connect-provider` returned `arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/…`. After the Step 22 recovery the cluster got a new issuer ID, so I deleted the stale provider and registered the new one |
| 3 | A role whose trust policy names that provider and `system:serviceaccount:usms:usms-enrolment-sa` | Not created: nothing could ever assume it |
| 4 | Annotate the ServiceAccount with the role ARN | `usms-enrolment-sa` exists (`manifests/lab-07/60-serviceaccount.yaml`), unannotated |
| 5 | The mutating webhook injects the token and env vars | **Absent.** k3s has no EKS Pod Identity webhook |
| 6 | The SDK calls `AssumeRoleWithWebIdentity` | Cannot happen without 1 (a reachable issuer that matches the token's `iss`) and 5 |

So IRSA is **Conceptual / Real AWS** here. I wrote the ServiceAccount, registered the provider and traced the chain; I did not configure IRSA.

## Step 22: persistence, honestly

**The AWS half persisted; the Kubernetes half did not.**

- After `floci-down.sh` / `floci-up.sh`, `list-clusters` and `list-nodegroups` re-derived `usms-eks-cluster` (`ACTIVE`, 1.30) and `usms-eks-nodes`, and the roles, policies and SG were intact.
- Floci logged `Stopped k3s container for cluster usms-eks-cluster` on shutdown, and the container was **removed**, not just stopped. Floci 1.7 does not start it again on boot. `kubectl` got `connection refused` on `localhost:6500`. The k3s datastore lived inside that container; `~/floci-data/eks/` holds only the token-webhook and registry configuration. **Every namespace, Deployment, ConfigMap and Secret was gone.** The diff in `outputs/lab-07-step22-diff.txt` shows exactly that.
- `floci-storage-check.sh` confirms storage mode is `hybrid`: this is not the memory-mode failure from Troubleshooting 9, but Floci not persisting the k3s state at all.

**Recovery** (`outputs/lab-07-step22-recovery.txt`): delete the node group, then the cluster, and recreate both from the committed `templates/lab-07-create-cluster.json` and `-nodegroup.json` (again as `usms-developer-role`). This gave a new k3s container on the same endpoint and the same `_lb_ports_` tag. Then **`kubectl apply -f manifests/lab-07/`** recreated all 13 objects in **1.0 second**. The only thing a manifest did not hold was Step 17's imperative `set env`, which had to be run again; that is the argument for folding it into `20-enrolment.yaml`. After recovery the diff against the "before" file shows only the three **ClusterIPs** changed, and the gateway did not care, because it addresses names.

The restart also stopped the ECS tasks (Floci replaced them within two minutes) and left one ALB target with no container behind it (`172.19.0.9`), which I deregistered (`outputs/lab-07-step22-orphans.txt`). The four Lab 03 EC2 instances had been stopped since an earlier restart; I started them one at a time so `verify-lab-03.sh` returns to `FAIL=0`.

**What this means for Lab 08:** after any Floci restart or reboot, run `./scripts/utilities/eks-recover.sh` before anything else (see "Repairs after the lab"). Take the Section 16 snapshot, but know it saves only the AWS half.

## Repairs after the lab (2026-10-17 and 2026-10-18)

Asked to repair what the lab left broken, I fixed four things. Each is a local workaround for Floci, not AWS behaviour, and is labelled as such.

| Problem | Repair | Evidence |
|---|---|---|
| `_lb_ports_` stored but ports 8081/8082 not published | `usms-eks-lbfwd` (socat, `127.0.0.1` only, `--restart unless-stopped`) forwards host 8081/8082 to the k3s container **by name**, so it keeps working after a recreate | `outputs/lab-07-repair-lbports.txt` |
| One node; the node group provisions none | `eks-nodes-join.sh` reads `desiredSize` and `labels` from the node group record and joins that many k3s agents (same version, v1.34.1). It had to solve three problems on the way: the host's `fs.inotify.max_user_instances=128` ("too many open files"; raised to 512 with `sudo`), stale `*.node-password.k3s` secrets ("hash does not match"; now deleted before a rejoin), and nginx pulls stalling for minutes on a fresh node (images now copied from the server node's cache, Troubleshooting 6) | `outputs/lab-07-repair-nodes.txt`, `lab-07-repair-crossnode.txt` (12 requests answered by both agent nodes) |
| Step 17's secret wiring existed only as an imperative `set env` | Declared in `20-enrolment.yaml` (`kubectl diff` showed the live object already matched), so one `kubectl apply -f manifests/lab-07/` restores everything | `manifests/lab-07/20-enrolment.yaml` |
| A restart or reboot leaves the cluster unreachable | `scripts/utilities/eks-recover.sh`, below | `outputs/lab-07-repair-reboot.txt`, `lab-07-repair-recover-test.txt` |

**What a machine reboot does (a second failure mode, unlike Step 22):** after the reboot on 2026-10-17 the k3s container was **stopped, not removed**, so its data was intact, but it would not start, for two reasons:

1. `failed to find interface with specified node ip`: the ECR registry container had started first and taken the k3s node's recorded bridge address, `172.17.0.3`. Restarting the registry first (it takes `.2`) and then k3s gives k3s its old address back.
2. `kubectl`: `the server has asked for the client to provide credentials`. The API server validates `aws eks get-token` tokens through a webhook that Floci wrote with **Floci's IP at creation time** (`http://172.19.0.2:4566/...`), and after the reboot Floci was at `172.19.0.3`. Pointing it at `http://floci.:4566/...` (the container name, resolved by Docker's DNS) fixes it for every future reboot.

After both fixes every object was still there with the **same pod names**: nothing was recreated (`outputs/lab-07-repair-reboot.txt`).

**`eks-recover.sh`** handles both cases. If the k3s container exists, it restarts the registry and then k3s, patches the webhook, rejoins the agents, waits for every Deployment and smoke-tests the gateway. If the container is gone (Step 22's `floci-down.sh` case), it recreates the node group and cluster from the templates, re-registers the OIDC provider and applies the manifests. On a healthy cluster it does nothing. **Tested** on 2026-10-18 by stopping k3s and the registry the way a reboot does: back in **64 s**, `SMOKE TEST PASSED`. The recreate path repeats the commands run by hand in Step 22 but has not itself been run end to end.

## Step 23

Path A: all 21 values populated, including `USMS_EKS_ENDPOINT=https://localhost:6500` and `USMS_EKS_LB_PORTS=8081,8082`.

## Floci limitations hit in this lab (Floci 1.7.0)

| What happened on Floci | What real AWS would have done |
|---|---|
| The cluster ran **k3s v1.34.1** although `version` is `1.30` everywhere in the AWS API | Kubernetes 1.30 exactly |
| The API endpoint is `https://localhost:6500` (a host port), not the lab's 6443 | A regional HTTPS endpoint, public and/or private per `resourcesVpcConfig` |
| `ACTIVE` within ~30 s; the node group `ACTIVE` in its own create response | 10-15 minutes for the control plane, several more for nodes |
| One k3s server node; the node group creates no node, `t3.small` and `AL2023_x86_64_STANDARD` are stored only, node labels `workload=usms tier=app` are not applied (**repaired** with two joined k3s agents) | Two EC2 instances in the private subnets, an Auto Scaling group, labels on each node |
| Pods get `10.42.x.x` addresses, Services `10.43.x.x`, while `describe-cluster` reports `serviceIpv4Cidr 10.100.0.0/16` | The VPC CNI gives pods addresses from `10.0.0.0/16`'s subnets; Services from the reported CIDR |
| `_lb_ports_` stored, but the k3s container publishes only 6443 → 6500 (**repaired** with `usms-eks-lbfwd` on `127.0.0.1`) | An ordinary tag, ignored |
| `sts assume-role` session name returned as `floci-session` | The session name you passed |
| The OIDC issuer URL returns 404 and differs from the token issuer k3s uses; no IRSA webhook | A reachable discovery document; IRSA works end to end |
| IAM policies on both roles are stored, never evaluated | A missing permission fails cluster creation or node registration |
| **A Floci restart removed the k3s container and all Kubernetes state; the cluster record still said `ACTIVE`** (recovered with `eks-recover.sh`) | The control plane and etcd are AWS-managed and survive anything you do locally |
| After a machine reboot the stopped k3s container lost its bridge IP to the ECR registry, and its token webhook pointed at Floci's old IP (both **repaired**) | Not applicable |
| The restart stopped the ECS tasks and left a dead ALB target; EC2 instances stay stopped | Nothing on the operator's laptop affects either |

**Lab text differences and bugs:**

- Step 17 says `set env --from=secret` adds an `envFrom.secretRef`; kubectl 1.36 adds per-key `secretKeyRef` entries instead (same effect).
- Checkpoint 6's revision numbers assume Step 17 did not roll the Deployment; it did, so I ended on revision 5, not 3.
- Step 18 "Your turn" expects the default strategy to roll differently from `maxUnavailable: 0`; at 2 replicas the rounding makes them identical (see above).
- Exercise 3 asks for a one-line fix but has two independent faults; each fault took one line, two lines in total.
- `lab-07-cleanup.sh` as written would leave the Step 21 OIDC provider behind. I added a step that reads the issuer before the cluster is deleted, and deletes that provider.
- The verify script's `no secret is tracked by git` check got the same one-line `outputs/.gitkeep` fix as Labs 04 to 06.
- Leftovers from the lab's old numbering are kept as written: the namespace label `lab: "05a"` and the session name `lab05a-eks-build`.
- kubectl client v1.36 against server v1.34 prints a version-skew warning; nothing used here was affected.

**Verification:** `verify-lab-07.sh` reports **`PASS=30 FAIL=0`** (Path A), re-checked on 2026-10-18 after the repairs. Labs 02, 03 and 04 are `FAIL=0`; 05 and 06 keep their documented benign failures (2 and 3). The reboot had stopped the Lab 03 instances again and left two dead ALB targets; I started the instances and deregistered only the targets with no task behind them (`outputs/recheck-orphans.txt`), and web-01 got HTTP 200 through the ALB.

## Exercise 5 Part 3: what Lab 08 needs from `configs/lab-07.env`

- `USMS_EKS_CLUSTER`: every `aws eks` call in Lab 08 names the cluster, and the kubeconfig context is built from it.
- `USMS_EKS_NODEGROUP`: Lab 08 Step 10 resizes the node group with `update-nodegroup-config`. On Floci that changes only a stored number; re-running `eks-nodes-join.sh` turns the new `desiredSize` into real nodes.
- `USMS_EKS_NAMESPACE`: every `kubectl` command works inside `usms`.
- `USMS_EKS_LB_PORTS`: the LoadBalancer Service in Step 15 needs a published host port. It reads `8081,8082`; Floci does not publish them, but `usms-eks-lbfwd` now serves them on `127.0.0.1`.
- `USMS_EKS_ENDPOINT`: after a restart (and a recreate), it confirms `kubectl` is talking to the right API server (`https://localhost:6500`). `eks-recover.sh` is the first command after any restart.
- `USMS_K8S_DEPLOY_ENROLMENT`: the Deployment the HorizontalPodAutoscaler targets.
- `USMS_K8S_DEPLOY_GATEWAY` and `USMS_K8S_SVC_GATEWAY`: the gateway is what becomes a NodePort, then a LoadBalancer, then sits behind an Ingress.
- `USMS_K8S_CPU_REQUEST`: `50m` is the divisor of the HPA's percentage; with the 1m baseline measured in Part 1 that is 2%.
- `USMS_K8S_MANIFEST_DIR`: after any Floci restart the whole application is one `kubectl apply -f` of this directory.

Not needed by Lab 08: the IAM ARNs, the SG and the results names are records of this lab.

## Review Questions

### 1. `ACTIVE`, yet every pod is `Pending`

`ACTIVE` describes only the **control plane**: the API server is up and will accept objects. Pods run on the **data plane**, which is separate capacity. A Deployment is stored the moment the API accepts it, and its pods are created; but the scheduler can only bind them to a node with room, so with no usable node they sit in `Pending` with `FailedScheduling`, while the cluster is perfectly healthy. Two configurations that produce it:

- **No node group at all, or nodes that never joined.** For example, a node role trusting `eks.amazonaws.com` instead of `ec2.amazonaws.com`, or missing `eks:DescribeCluster`, so the kubelet cannot register.
- **Nodes that exist but cannot take the pod:** only control-plane nodes with their `NoSchedule` taint (Troubleshooting 4), a `nodeSelector` such as Lab 08's `workload=usms` that no node carries (true of Floci's single server node until I joined labelled agents), or requests larger than any node, as `usms-toobig` showed in Step 19.

### 2. Swapping the two trust policies

The cluster role would trust `ec2.amazonaws.com` and the node role `eks.amazonaws.com`.

- **Step 8 (`create-cluster`)** is where real AWS fails first. EKS must assume the cluster role, the trust policy does not name `eks.amazonaws.com`, and `create-cluster` is rejected with an error that the role cannot be assumed by EKS.
- If that were fixed first, **Step 10 / Step 11** would fail next. The EC2 instances could not assume a role that trusts only `eks.amazonaws.com`, so the node group would go to `CREATE_FAILED` (or its instances would never join), and `kubectl get nodes` would show nothing.

On Floci neither happens: trust policies are stored, never evaluated. That is why Steps 6 and 7 verify the `Principal.Service` by reading it, and why `verify-lab-07.sh` checks both.

### 3. Readiness versus liveness

**Readiness** decides whether a pod is in the Service's endpoints. Failing it removes the pod from traffic but leaves it running. **Liveness** decides whether the container is restarted. Failing it kills the container.

**Getting it backwards:** put a load-sensitive check (say, "respond to `/healthz` within one second, including a database round trip") on **liveness**. Under the enrolment-day spike every pod slows down, every liveness probe times out, the kubelet restarts every pod at once, and capacity falls to zero exactly when it is needed: a self-inflicted outage. The same check on readiness would only have shed the slowest pods for a moment. Exercise 3 showed the other side: a readiness probe pointing at a path that does not exist (`/healthz` on stock nginx) keeps healthy, Running pods out of the Service forever, with no restart and no error, just `<none>` endpoints.

### 4. "Kubernetes rollback is not really a rollback"

The pod still said `1.1.0` because `rollout undo` restores the **pod template** of an earlier ReplicaSet and nothing else. `APP_VERSION` lives in the `usms-app-config` ConfigMap, which is a separate object with no revision history, and the re-created pods read its *current* value.

**I argue for the statement, with a qualification.** It is a real rollback of what the Deployment owns: the image, command, environment *references* and probes. It is not a rollback of the *release*. A release that changed a ConfigMap, a Secret and an image recovers only the image. In an incident, an operator who believes `undo` restored everything is wrong in exactly the way that hurts.

**The practice that resolves it:** version configuration with the workload. Either give each configuration version an immutable name (`usms-app-config-v2`) referenced from the pod template, so the template change *is* the config change and `undo` reverts both, or deploy the whole release from Git (GitOps / a Helm or Kustomize release with a config hash in the template), where rolling back is reverting a commit.

### 5. `maxUnavailable: 0` against the default, at two replicas

- `usms-enrolment` (`maxUnavailable: 0`, `maxSurge: 1`): start one new pod, wait until it is Ready, remove one old one, and repeat. It never has fewer than 2 ready pods and briefly has 3.
- `usms-results` (default 25% / 25%): **at two replicas this is the same thing.** 25% of 2 is 0.5; Kubernetes rounds surge *up* to 1 and unavailability *down* to 0. My Step 18 "Your turn" measured it: peak 3 live pods, never below 2 ready. The default only becomes "one pod may be missing" at 4 or more replicas.

**Suited workloads:** `maxUnavailable: 0` suits anything where capacity must never dip during a deploy, such as the enrolment API at registration time, if the cluster has room for the surge pod. A non-zero `maxUnavailable` with no surge suits workloads where an extra pod is impossible or harmful (a fixed licence count, a node with no spare room, a singleton consumer) and a brief capacity dip is acceptable.

**Closest to Lab 04:** `usms-enrolment`'s explicit `maxUnavailable: 0`, `maxSurge: 1` matches ECS's `minimumHealthyPercent 100` (never below desired) with `maximumPercent 200` (extra tasks allowed during the roll).

### 6. "A Secret is encrypted, so it's fine to commit the manifest"

Correction: a Secret's `data` is **base64, an encoding, not encryption**. Step 17 decoded `ZmxvY2ktZHVtbXktdG9rZW4tbm90LWEtcmVhbC1zZWNyZXQ=` to `floci-dummy-token-not-a-real-secret` with a plain `base64 -d`, with no key, and anyone who can `get secret` or read the repository can do the same. A committed manifest puts that value into Git history permanently.

What a Secret *does* provide: a separate object type that RBAC can restrict separately from ConfigMaps, values kept out of images and out of `kubectl describe`, and delivery to the pod as environment or a file. It does not encrypt at rest unless etcd encryption is turned on, and inside the container the value is plain text (Step 17's `printenv`).

**On real EKS I would:**

- enable KMS envelope encryption of Secrets at cluster creation;
- keep the real value in AWS Secrets Manager, delivered by the Secrets Store CSI driver or External Secrets Operator;
- give the pod access through IRSA rather than stored AWS keys;
- restrict `get secret` with RBAC;
- never commit a Secret manifest. If the manifest must live in Git, use Sealed Secrets or SOPS, so only an encrypted form is committed.

### 7. ECS or Kubernetes for USMS

**ECS on Fargate.** USMS is a small team, in one region, with a long quiet period and a short, predictable peak. That profile rewards the platform with the least to run.

Things this lab made harder than Lab 04:

- **Two control planes and two IAM roles.** There is a second API with its own client and credentials, and both a cluster role and a node role, each with its own failure mode (Review Question 2).
- **A data plane to own.** There are nodes to size, patch and upgrade, and a node group whose desired count does not move by itself.
- **Fragile state, more objects and more ways to misconfigure them.** On this build the whole application vanished with one restart and had to be re-applied. Exercise 3 needed two independent faults (a selector and a probe) to make a Service silently empty.

What Kubernetes gave me that ECS could not:

- **Built-in DNS service discovery for every service, with no load balancer.** The gateway reached its backends by name, and kube-proxy spread the load beneath it (Step 16). On ECS that needs an ALB per service or Cloud Map.
- **The whole application as portable, declarative files.** One `kubectl apply -f manifests/lab-07/` rebuilt it in a second on a brand-new cluster.

If USMS grew to dozens of services, or had to leave AWS, that portability would tip the decision.
