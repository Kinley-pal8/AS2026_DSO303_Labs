# Lab 07 - Independent Exercises

All commands were run from `aws-floci-course/` against Floci 1.7.0 (support path **A**: `aws eks` creates a real single-node k3s cluster). Captured output is in `outputs/lab-07-ex*.txt` (git-ignored). The exercises ran on the cluster as recreated in Step 22, so pod hashes and ClusterIPs differ from Steps 13 to 19.

---

## Exercise 1 - Basic: a fourth microservice, `usms-timetable`

`manifests/lab-07/70-timetable.yaml` holds three objects, written by hand from `30-results.yaml`'s structure:

- **`usms-timetable-conf`** (ConfigMap): an nginx template that answers `/healthz` with `ok` and `/` with JSON naming the service, `${POD_NAME}`, `${APP_CAMPUS}` and `${APP_VERSION}`.
- **`usms-timetable`** (Deployment): 1 replica, `nginx:1.27-alpine`, labels `app` / `project` / `tier` exactly as in Step 13, requests `cpu 50m, memory 32Mi`, limits `200m / 128Mi`, a readiness probe on `/healthz`, the shared `usms-app-config` through `envFrom`.
- **`usms-timetable`** (Service): ClusterIP, port 80 to the named port `http`.

```bash
kubectl apply --dry-run=client -f manifests/lab-07/70-timetable.yaml     # validate first
kubectl apply -f manifests/lab-07/70-timetable.yaml
kubectl rollout status deployment/usms-timetable --timeout=120s
kubectl get deploy,svc -n usms
kubectl run usms-debug --rm -i --restart=Never --image=busybox:1.36 -- \
  wget -qO- http://usms-timetable.usms.svc.cluster.local/
```

```text
deployment.apps/usms-enrolment   2/2     2            2           4m49s
deployment.apps/usms-gateway     1/1     1            1           4m48s
deployment.apps/usms-results     2/2     2            2           4m48s
deployment.apps/usms-timetable   1/1     1            1           8s
service/usms-enrolment   ClusterIP   10.43.113.52    <none>        80/TCP    4m49s
service/usms-gateway     ClusterIP   10.43.209.227   <none>        80/TCP    4m48s
service/usms-results     ClusterIP   10.43.87.164    <none>        80/TCP    4m48s
service/usms-timetable   ClusterIP   10.43.184.108   <none>        80/TCP    8s
{"app":"usms-timetable","project":"usms","tier":"app"}
{"limits":{"cpu":"200m","memory":"128Mi"},"requests":{"cpu":"50m","memory":"32Mi"}}
{"service":"usms-timetable","pod":"usms-timetable-cf6b9c8fb-7mnvs","campus":"rtc","version":"1.0.0"}
```

Four Deployments, four Services, and the busybox pod gets JSON naming the service and its pod.

---

## Exercise 2 - Intermediate: route `/timetable/` through the gateway

I edited `manifests/lab-07/40-gateway.yaml`. The change adds one `location` block and adds `/timetable/` to the root route list:

```nginx
location /timetable/ {
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_pass http://usms-timetable.usms.svc.cluster.local/;
}
```

```bash
kubectl apply -f manifests/lab-07/40-gateway.yaml
```

```text
configmap/usms-gateway-conf configured
deployment.apps/usms-gateway unchanged
service/usms-gateway unchanged
NAME                      DESIRED   CURRENT   READY   AGE
usms-gateway-58854c9ffd   1         1         1       5m9s          <- still the only ReplicaSet
/timetable/ -> wget: server returned error: HTTP/1.1 404 Not Found     <- the running nginx has the old config
```

The ConfigMap changed but the pod template did not, so nothing rolled. Of Step 18's two instruments, `kubectl annotate` touches only the Deployment's own metadata. **`kubectl rollout restart`** is the one that works when the template is otherwise unchanged: it writes `kubectl.kubernetes.io/restartedAt` into the pod template.

```bash
kubectl rollout restart deployment/usms-gateway
kubectl rollout status deployment/usms-gateway --timeout=120s
```

```text
NAME                      DESIRED   REVISION
usms-gateway-58854c9ffd   0         1
usms-gateway-c65b8848b    1         2          <- new ReplicaSet, caused by rollout restart
{"kubectl.kubernetes.io/restartedAt":"2026-10-16T09:30:48+06:00"}
/enrolment/ -> {"service":"usms-enrolment","pod":"usms-enrolment-7d8557c58d-qfv5x",...,"version":"1.0.0"}
/results/ -> {"service":"usms-results","pod":"usms-results-7fc784c47f-lxdm2","campus":"rtc","version":"1.0.0"}
/timetable/ -> {"service":"usms-timetable","pod":"usms-timetable-cf6b9c8fb-7mnvs","campus":"rtc","version":"1.0.0"}
```

All three routes answer in one command, from three services, and `rollout history deployment/usms-gateway` gained one revision (1 → 2).

---

## Exercise 3 - Problem solving: find the misconfiguration

I applied the manifest exactly as given (kept in `outputs/lab-07-ex3-usms-broken.yaml`) and diagnosed it with commands, in this order:

| # | Command | What it showed |
|---|---|---|
| 1 | `wget http://usms-broken.usms.svc.cluster.local/` from busybox | `can't connect to remote host (10.43.215.148): Connection refused`, so the Service exists but nothing is behind it |
| 2 | `kubectl get endpoints usms-broken` (Step 13's most useful command) | `<none>` |
| 3 | `kubectl get svc usms-broken -o jsonpath='{.spec.selector}'` and `kubectl get pods -l app=usms-broken --show-labels` | Selector `{"app":"usms-broken","version":"v2"}`; pods labelled `app=usms-broken,…,version=v1`; `kubectl get pods -l app=usms-broken,version=v2` returns no resources |
| 4 | `kubectl get pods … READY condition` | Both pods `Running` but Ready `False` |
| 5 | `kubectl get events --field-selector reason=Unhealthy` and `kubectl describe pod` | `Readiness probe failed: HTTP probe failed with statuscode: 404` on `http-get http://:http/healthz` |
| 6 | `kubectl exec deploy/usms-broken -- wget -S http://127.0.0.1/healthz` | `HTTP/1.1 404 Not Found`: stock nginx serves no `/healthz` |

**Diagnosis:** the Service selects `version: v2` while the pods are `version: v1`, so it matches no pod. Separately, the readiness probe asks stock nginx for `/healthz`, which it does not serve, so the pods would never be Ready, and a not-Ready pod is never an endpoint.

**Fixes**, one line per fault. The brief says "exactly one line", but no single line fixes two independent faults:

```diff
-              path: /healthz
+              path: /
-    version: v2
+    version: v1
```

Fixing the selector first, on its own, **still left the endpoints empty**, which proves the two faults are independent. After the probe fix the Deployment rolled:

```text
usms-broken-54fbb876bb-cnwws   1/1     Running   0          7s
usms-broken-54fbb876bb-qb9sg   1/1     Running   0          7s
usms-broken   10.42.0.21:80,10.42.0.22:80   64s
<title>Welcome to nginx!</title>
```

Two endpoints and a working Service. **CLEAN UP:** `kubectl delete deployment,service usms-broken` was run, and `kubectl get deploy,svc -n usms` shows only the four USMS services.

---

## Exercise 4 - Challenge: survive a node going away

Floci built **one schedulable node** (`c439abeaf203`, the k3s server; the node group adds none). I first demonstrated what one node allows. After the repair that joined the node group's two nodes (`usms-eks-node-1` and `-2`, via `scripts/utilities/eks-nodes-join.sh`; see the notes, "Repairs after the lab"), I repeated it as the exercise intends: a whole node drained while traffic flows.

Changes to `manifests/lab-07/20-enrolment.yaml` (no new Deployment):

```yaml
      topologySpreadConstraints:          # advisory (pod spec)
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              app: usms-enrolment
      ...
          lifecycle:                      # added after the first 3-node drain lost a request
            preStop:
              exec:
                command: ["sleep", "5"]
---
apiVersion: policy/v1                   # enforced - the new object
kind: PodDisruptionBudget
metadata:
  name: usms-enrolment-pdb
  namespace: usms
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: usms-enrolment
```

**Justification:**

- **Not all capacity on one node: `topologySpreadConstraints` on `kubernetes.io/hostname`, `maxSkew: 1`.** On two or more nodes the scheduler puts the two replicas on different nodes, so losing one node loses half the capacity, not all of it. I chose `ScheduleAnyway` (advisory) rather than `DoNotSchedule`. With `DoNotSchedule`, a one-node cluster, or a cluster that has just lost a node, would leave the second replica `Pending`, and the `maxSurge: 1` roll would deadlock. For the same reason I chose this over a *required* `podAntiAffinity`, which has the same hard failure mode. A *preferred* anti-affinity would also work; the spread constraint says the same thing more directly and scales to more replicas.
- **Never below one healthy pod during a voluntary disruption: a `PodDisruptionBudget` with `minAvailable: 1`.** This is the enforced half. The eviction API, which `kubectl drain`, node upgrades and the cluster autoscaler all use, refuses any eviction that would leave fewer than one Ready pod. It does not protect against involuntary loss (a node crashing); only the spread does.
- **Which node each pod is on, from the cluster: `kubectl get pods -l app=usms-enrolment -o wide`.** The `NODE` column comes from each pod's `spec.nodeName`, and the pods already report it themselves in their JSON (`"node":"usms-eks-node-2"`).
- **A `preStop` sleep of 5 s.** Neither the spread nor the PDB covers the moment a pod is killed: kube-proxy and the gateway may still send it a request before its removal from the Service's endpoints has propagated. Keeping the container serving for a few seconds after termination begins closes that window. The 3-node demonstration below measured the difference: 1 failure in 75 without it, 0 in 75 with it.

**Demonstration 1, one node (as Floci built it).** A busybox pod requested `/enrolment/` through the gateway once a second for 45 seconds, while I drained the enrolment pods off the only node:

```bash
kubectl drain c439abeaf203 --pod-selector=app=usms-enrolment --timeout=30s
```

```text
node/c439abeaf203 cordoned
evicting pod usms/usms-enrolment-8549846ddd-mqzrz
evicting pod usms/usms-enrolment-8549846ddd-5f6t9
error when evicting pods/"usms-enrolment-8549846ddd-mqzrz" -n "usms" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
pod/usms-enrolment-8549846ddd-5f6t9 evicted
...global timeout reached: 30s
usms-enrolment-8549846ddd-mqzrz   1/1     Running   0          53s   10.42.0.24   c439abeaf203
usms-enrolment-8549846ddd-sk8z8   0/1     Pending   0          32s   <none>       <none>
usms-enrolment-pdb   1               N/A               0                     53s
```

The first eviction was allowed (two Ready, one may go). Its replacement could not schedule on the cordoned node and stayed `Pending`, so the PDB's `ALLOWED DISRUPTIONS` fell to **0**, and the second eviction was refused, repeatedly, until the drain timed out. After `kubectl uncordon`, the replacement started and the Deployment returned to 2/2. **The smoke loop recorded 45 `ok` and no failed request.**

`--pod-selector` limited the drain to the enrolment pods, so it did not also evict CoreDNS, metrics-server and the other USMS services from the only node.

**Demonstration 2, three nodes (after the repair).** `kubectl rollout restart` let the spread constraint place the replicas: one enrolment pod on `usms-eks-node-1`, one on `usms-eks-node-2`, and 12 requests through the gateway were answered 5 / 7 by the two agent nodes (cross-node pod networking works). The smoke pod was pinned to the control-plane node with `--overrides '{"spec":{"nodeName":"c439abeaf203"}}'`. In the first try it landed on node-1 itself, and `drain` correctly refused to delete a bare pod with no controller. Then I drained the **whole** node:

```bash
kubectl drain usms-eks-node-1 --ignore-daemonsets --delete-emptydir-data --timeout=120s
```

```text
node/usms-eks-node-1 cordoned
evicting pod usms/usms-results-bb844bd7c-5z74n
evicting pod usms/usms-enrolment-84489fffd6-87pgk
pod/usms-results-bb844bd7c-5z74n evicted
pod/usms-enrolment-84489fffd6-87pgk evicted
node/usms-eks-node-1 drained                         <- completes in 2 s: the replacement had somewhere to go
usms-enrolment-84489fffd6-58czh   0/1     Running   0    3s    10.42.0.59   c439abeaf203
usms-enrolment-84489fffd6-9n6vd   1/1     Running   0    2m8s  10.42.2.2    usms-eks-node-2
smoke loop:  74 ok, 1 FAIL (17:30:45, the moment the evicted pod stopped)
```

The drain completed and one replica stayed Ready throughout, so the PDB requirement held. But **one request failed**: the endpoint-propagation race described above. I added the `preStop` sleep, rolled the Deployment, and drained `usms-eks-node-1` again:

```text
pod/usms-enrolment-7f7d8b8dbd-76b5r evicted
node/usms-eks-node-1 drained
usms-enrolment-7f7d8b8dbd-bwngc   1/1     Running   0    8s    10.42.2.5    usms-eks-node-2
usms-enrolment-7f7d8b8dbd-qflnm   1/1     Running   0    27s   10.42.0.60   c439abeaf203
smoke loop:  75 ok, no failed request
```

**75 of 75 requests succeeded through a whole-node drain** (`outputs/lab-07-ex4-3nodes.txt`, `outputs/lab-07-ex4-3nodes-prestop.txt`). The node was uncordoned afterwards.

---

## Exercise 5 - Integration: what Lab 08 needs, using what Lab 01 built

**Part 1: CPU baseline** (`outputs/lab-07-cpu-baseline.txt`). The metrics API **is present** (k3s ships metrics-server: `v1beta1.metrics.k8s.io kube-system/metrics-server True`), so `kubectl top` works:

```text
usms-enrolment-8549846ddd-mqzrz      cpu=1m  = 2% of 50m request   memory=10Mi
usms-enrolment-8549846ddd-sk8z8      cpu=1m  = 2% of 50m request   memory=9Mi
```

An idle pod uses about 1m, which is **2% of its 50m request**, the number Lab 08's HPA will compute.

**Part 2: `USMSStudentDataReadWrite`, read from IAM** (`outputs/lab-07-lab06-readiness.txt`). The ARN was looked up by name, then `get-policy` (default version `v1`) was chained into `get-policy-version`. The bucket name was parsed out of the document's `Resource` fields, not typed:

```text
policy ARN      : arn:aws:iam::000000000000:policy/USMSStudentDataReadWrite
roles carrying it:
  - usms-ec2-app-role
  - usms-ecs-task-role
  - usms-eks-node-role
statements (Sid -> Resource):
  ListTheBucketItself	arn:aws:s3:::usms-student-data
  ReadWriteObjectsInsideTheBucket	arn:aws:s3:::usms-student-data/*
  NeverDeleteTheBucket	arn:aws:s3:::usms-student-data
bucket ARN      : arn:aws:s3:::usms-student-data   (ListBucket: the bucket itself)
object ARN      : arn:aws:s3:::usms-student-data/*   (Get/PutObject: keys inside it)
bucket exists   : NO - head-bucket fails; Lab 10 creates it
```

The bucket ARN (no `/`) is what `s3:ListBucket` and the deny on `DeleteBucket` apply to. The object ARN (`/*`) is what `GetObject` / `PutObject` apply to. Lab 10 depends on keeping the two apart.

Both files are git-ignored:

```text
aws-floci-course/.gitignore:8:outputs/*	outputs/lab-07-cpu-baseline.txt
aws-floci-course/.gitignore:8:outputs/*	outputs/lab-07-lab06-readiness.txt
```

A copy of both, holding no secrets, is kept in `labs/lab-07-eks/lab08-readiness.txt` for the report.

**Part 3:** appended to `notes/lab-07-notes.md` ("Exercise 5 Part 3"): ten of the 21 variables, one line each with the reason, and the warning that `USMS_EKS_LB_PORTS` is set but its ports are not yet published.
