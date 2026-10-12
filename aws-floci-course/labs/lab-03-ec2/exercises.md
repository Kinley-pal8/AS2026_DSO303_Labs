# Lab 03 - Independent Exercises

All commands were run from `aws-floci-course/` against Floci 1.7.0 with `configs/course.env`, `lab-01.env`, `lab-02.env` and `lab-03.env` sourced.

---

## Exercise 1 - Basic: a maintenance instance

**Command** (long form, waiter rather than sleep):

```bash
ADMIN_ID=$(aws ec2 run-instances \
  --image-id "$USMS_BASE_AMI" --instance-type t3.micro --key-name usms-app-key \
  --subnet-id "$USMS_PUBLIC_SUBNET_B" --security-group-ids "$USMS_APP_SG" \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-admin-01-host},{Key=Project,Value=USMS},{Key=Tier,Value=admin},{Key=Lab,Value=03},{Key=Ephemeral,Value=true}]' \
  --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --instance-ids "$ADMIN_ID"

aws ec2 describe-instances \
  --filters "Name=tag:Tier,Values=admin" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,Id:InstanceId,State:State.Name,AZ:Placement.AvailabilityZone,Profile:IamInstanceProfile.Arn,SG:SecurityGroups[0].GroupName}' \
  --output table
```

**Output**

```text
------------------------------------
|         DescribeInstances        |
+----------+-----------------------+
|  AZ      |  us-east-1b           |
|  Id      |  i-f99c55305e6d3c491  |
|  Name    |  usms-admin-01-host   |
|  Profile |  None                 |
|  SG      |  usms-app-sg          |
|  State   |  running              |
+----------+-----------------------+
```

Exactly one running `Tier=admin` instance in `us-east-1b`, with no instance profile. It is not recorded in `configs/lab-03.env`, and Exercise 4 terminates it.

**Floci issue encountered:** the first two launch attempts (`i-20bc086530a082091`, `i-41b909dc38373a781`) went straight to `terminated`, so the waiter failed with `matched expected path: "terminated"`. Floci's log showed `Bind for :::2200 failed: port is already allocated`: after the Step 19 restart, Floci's SSH host-port counter restarted at 2200 while the restored instance containers still held 2200 to 2202. The counter advances on each attempt, so a retry succeeded. Real AWS has no equivalent failure.

---

## Exercise 2 - Intermediate: a self-describing bootstrap

`labs/lab-03-ec2/user-data-db.sh` (1,477 bytes, well under 16 KB; `bash -n` passes):

```bash
#!/bin/bash
# USMS data tier bootstrap. Runs as root at first boot via cloud-init.
# Idempotent: a marker file records a completed run, and a second run exits early.
MARKER=/var/log/usms-db-bootstrap.done
if [ -f "$MARKER" ]; then
  echo "USMS db bootstrap already done: $(cat "$MARKER")"; exit 0
fi
set -euxo pipefail
exec >> /var/log/usms-db-bootstrap.log 2>&1

# Instance ID from IMDSv2, falling back to the env var Floci injects.
TOKEN=$(curl -s --max-time 2 -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" || true)
INSTANCE_ID=$(curl -s --max-time 2 -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id" || true)
INSTANCE_ID=${INSTANCE_ID:-${AWS_EC2_INSTANCE_ID:-unknown}}

# Install PostgreSQL with whichever package manager this image has.
if command -v dnf >/dev/null; then
  dnf -y install postgresql15-server
  postgresql-setup --initdb
elif command -v yum >/dev/null; then
  amazon-linux-extras enable postgresql14 >/dev/null 2>&1 || true
  yum -y install postgresql-server
  postgresql-setup initdb || postgresql-setup --initdb
fi
systemctl enable --now postgresql

# Create the usms database only if it does not exist yet.
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='usms'" | grep -q 1; then
  sudo -u postgres createdb usms
fi

printf '%s %s\n' "$INSTANCE_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
echo "USMS db bootstrap complete"
```

Design notes:

- **Why the outer heredoc is quoted (`<< 'EOF'`):** so `$(cat "$MARKER")`, `${INSTANCE_ID}` and `$(date ...)` are written literally and evaluated on the instance at boot, not expanded by the laptop's shell when the file is written.
- **Idempotent:** the marker check is the first thing the script does, and the marker is written only as the *last* step, so an interrupted run is retried rather than wrongly skipped. `createdb` is additionally guarded by a `pg_database` lookup.
- The package-manager branch exists because Step 14 showed that a `dnf`-only script silently fails on the Amazon Linux 2 AMI this lab uses.

**Launch and proof:**

```bash
aws ec2 run-instances --image-id "$USMS_BASE_AMI" --instance-type t3.micro --key-name usms-app-key \
  --subnet-id "$USMS_PRIVATE_SUBNET_B" --security-group-ids "$USMS_DB_SG" \
  --user-data file://labs/lab-03-ec2/user-data-db.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=usms-db-02},{Key=Project,Value=USMS},{Key=Tier,Value=data},{Key=Lab,Value=03}]' \
  --query 'Instances[0].InstanceId' --output text
# i-2e142252f014c1f12  running  subnet-0d751e14 (usms-private-subnet-b)  us-east-1b  Public: None
```

Step 12's technique, adapted because Floci 1.7 returns no `userData` attribute (see notes): the script Floci delivered to the instance is compared with the source.

```text
$ docker exec floci-floci-course-ec2-i-2e142252f014c1f12 cat /tmp/user-data.sh | diff labs/lab-03-ec2/user-data-db.sh - && echo 'USER DATA PROVEN (usms-db-02): byte-identical'
USER DATA PROVEN (usms-db-02): byte-identical
abdcffaeb10b5ee079c6701da556378c4be2815f6aea5ce90603f342f2cf6a6a  labs/lab-03-ec2/user-data-db.sh
abdcffaeb10b5ee079c6701da556378c4be2815f6aea5ce90603f342f2cf6a6a  outputs/lab-03-userdata-db-on-instance.sh
```

**Idempotence demonstrated.** On Floci the first run took the `yum` branch correctly but stalled inside `yum install` (slow package mirrors from inside the container, and there is no systemd to start PostgreSQL anyway), so it never reached the marker. To exercise the guard, a marker was placed on the instance by hand (simulating a completed first run) and the script was run a second time:

```text
$ docker exec floci-floci-course-ec2-i-2e142252f014c1f12 bash /tmp/user-data.sh; echo exit=$?
USMS db bootstrap already done: i-2e142252f014c1f12 2026-10-12T18:14:31Z
exit=0
```

It exited immediately with status 0 and the bootstrap log did not grow (12 lines before and after).

**When could a re-run actually happen, given that user data normally runs once?**

- An operator re-runs it by hand while debugging (`sudo bash /var/lib/cloud/instance/scripts/part-001`).
- Someone runs `cloud-init clean` and reboots, or replaces the user data with `modify-instance-attribute` and forces cloud-init to treat the instance as new.
- The user data is delivered as MIME multi-part with a per-boot or `always` frequency.
- **An AMI is made from this instance** (as Step 20 did for the web tier). cloud-init sees a new instance ID on every launch from that AMI and runs the user data again. Note the trap: the marker lives in `/var/log`, which is baked into the image, so a database launched from such an AMI would skip its bootstrap. A golden-image pipeline must delete the marker (or key it on the instance ID) before `create-image`.

---

## Exercise 3 - Problem solving: a reachability report

Script: `scripts/utilities/lab-03-reachability.sh`. For each running `Project=USMS` instance it:

1. resolves the subnet's route table (explicit association, else the VPC main table),
2. checks for a `0.0.0.0/0` route whose target starts with `igw-`,
3. checks for a public address,
4. checks that one of the instance's security groups admits TCP 80 from `0.0.0.0/0` (including `-1`, all-traffic rules).

The verdict comes only from those facts, never from names or tags. It uses `set -uo pipefail` *without* `-e`, justified in a comment: several lookups legitimately return nothing, and one odd instance must not abort the report for the others. `None` values are normalised before comparison, and it locates `configs/` from its own path, so it runs from any directory.

**Output from `~` and from `labs/lab-03-ec2/`, identical (`diff` empty):**

```text
usms-db-02           172.19.0.8   -               UNREACHABLE  no igw route on subnet
usms-web-01          172.19.0.3   127.0.0.1       REACHABLE    igw route + sg allows 80/tcp from 0.0.0.0/0
usms-db-01           172.19.0.4   -               UNREACHABLE  no igw route on subnet
usms-admin-01-host   172.19.0.6   127.0.0.1       REACHABLE    igw route + sg allows 80/tcp from 0.0.0.0/0
usms-web-02          172.19.0.5   127.0.0.1       REACHABLE    igw route + sg allows 80/tcp from 0.0.0.0/0
```

The `NO-ADDRESS` branch (an IGW route but no public address) was not exercised by a live instance, because both public subnets have `MapPublicIpOnLaunch=True` and Floci reports `127.0.0.1` for every public-subnet instance. It would trigger on real AWS for an instance launched into a public subnet with `--no-associate-public-ip-address`. A fourth verdict, `BLOCKED`, covers an IGW route plus a public address but no security-group rule for port 80.

---

## Exercise 4 - Challenge: right-size and clean up

### The situation

400 concurrent users, read-mostly, one `t3.micro` at **85% CPU at midday** and idle overnight.

### Burstable CPU credits, and why 85% sustained is a specific problem for a `t3`

A `t3.micro` has 2 vCPUs but a **baseline of 10% per vCPU**. It earns **12 CPU credits per hour** (1 credit = one vCPU at 100% for one minute) and can bank at most **288** (24 hours' worth). Anything above baseline spends credits. At 85% across 2 vCPUs it spends about 102 credits per hour while earning 12, so a full overnight bank of 288 lasts about **3 hours** of the midday peak.

What happens next depends on the **credit specification**, the setting the hint refers to:

- **`standard`:** the instance is throttled to the 10% baseline when credits run out. At midday that is a 90% drop in CPU, so the portal becomes unusable at exactly the busiest moment.
- **`unlimited`** (the default for T3): the instance keeps running at 85% and **bills surplus credits at USD 0.05 per vCPU-hour**. Performance is protected, but the bill grows silently.

On Floci the setting cannot be read (`describe-instance-credit-specifications` returns `UnsupportedOperation`). On real AWS:

```bash
aws ec2 describe-instance-credit-specifications --instance-ids "$USMS_WEB_INSTANCE"
```

Sustained 85% is the signal that the workload is no longer bursty, so a burstable instance is the wrong fit at its current size.

### Scale up or scale out

**Scale up** (one bigger instance). Moving from `t3.micro` to `t3.small` or `t3.medium` adds memory and baseline but **not vCPUs** (all three have 2), so it does not relieve 85% CPU saturation. A real scale-up needs more vCPUs, for example `t3.xlarge` (4 vCPU, 40% baseline per vCPU). It is simple and needs no architecture change, but it still runs 24 hours a day at peak size (overnight idle is paid for), and it is still one instance in one AZ.

**Scale out** (several smaller instances behind an Application Load Balancer, in an Auto Scaling group). This fits a read-mostly, stateless web tier:

- It adds capacity in steps.
- It spreads across `us-east-1a` and `us-east-1b`, removing the single point of failure.
- It **scales in overnight**, which is the only option that does anything about the idle hours.
- The web instances can move to private subnets behind the ALB, so they no longer need public addresses.
- Lab 8's launch template and the `usms-web-golden` AMI are built for exactly this.

### Monthly cost comparison (us-east-1, Linux, on-demand, 730 hours per month)

Prices are from AWS's public price lists:

- **Amazon EC2 On-Demand Pricing** (aws.amazon.com/ec2/pricing/on-demand/): `t3.micro` USD 0.0104/h, `t3.small` USD 0.0208/h, `t3.xlarge` USD 0.1664/h. The T3 Unlimited surplus credit price is USD 0.05 per vCPU-hour, on the same page.
- **Elastic Load Balancing Pricing** (aws.amazon.com/elasticloadbalancing/pricing/): ALB USD 0.0225/h plus USD 0.008 per LCU-hour.
- **Amazon VPC Pricing** (aws.amazon.com/vpc/pricing/): public IPv4 USD 0.005/h per address.

*Re-check the live pages before quoting to Finance.*

| Option | Calculation | Approx. USD / month |
|---|---|---|
| **0. Do nothing** (`t3.micro`, unlimited) | instance 730 × 0.0104 = 7.59. Credits: about 655 spent per day against 288 earned leaves 367 surplus credits a day, which is 6.1 vCPU-h × 30 × 0.05 = 9.18. Elastic IP 3.65 | **≈ 20.42**, and still at 85% CPU with no headroom and no HA |
| **1. Scale up** (`t3.xlarge`) | 730 × 0.1664 = 121.47, plus Elastic IP 3.65. Load ≈ 42% of 4 vCPUs, near the 40% baseline, so no surplus | **≈ 125.12**, single AZ, idle all night at full price |
| **2. Scale out** (ALB + ASG of `t3.small`, min 2 (one per AZ), 3 at the six-hour peak) | 2 × 730 × 0.0208 = 30.37, plus a third instance for 180 h × 0.0208 = 3.74. ALB 730 × 0.0225 = 16.43, plus about 1 LCU × 730 × 0.008 = 5.84. ALB public IPv4 for 2 AZs: 2 × 3.65 = 7.30. Instances move to private subnets, so they have no public IPs | **≈ 63.68** |
| 2b. Scale out, min 1 overnight (accept no HA at night) | as option 2, but 18 h/day × 30 at 1 instance: (18 × 1 + 6 × 3) × 30 × 0.0208 = 22.46 | **≈ 52.03** |

At peak, three `t3.small` instances each run at about 28% CPU. That is above their 20% baseline, but they earn 24 credits per hour each and bank up to 576 overnight, so the about 58 credits each spends at midday are always covered with **zero** surplus charges.

**Recommendation:** option 2. It costs about half of a real scale-up, is the only option that addresses both the midday saturation and the overnight idle time, and it adds the second-AZ resilience the single instance lacks. Finance's "too high" line is best answered by option 2b if overnight availability is not required. Either way, the immediate saving comes from deleting what is not used (below), and the single instance should be switched to `standard` credits only if throttling at peak is an acceptable trade for a hard cost ceiling.

### What I would delete today, in dependency order

> [!CAUTION]
> **What will be deleted:** `usms-admin-01-host` (`i-f99c55305e6d3c491`), the Exercise 1 practice instance, and its root volume (DeleteOnTermination True).
> **What depends on it:** nothing; it is tagged `Ephemeral=true` and is not in `configs/lab-03.env`.
> **Reversible?** No. A terminated instance cannot be restarted.
> **Effect on later labs:** none. It is in Section 15's CLEAN UP column.

```bash
aws ec2 terminate-instances --instance-ids i-f99c55305e6d3c491
aws ec2 wait instance-terminated --instance-ids i-f99c55305e6d3c491
```

> [!CAUTION]
> **What will be deleted:** orphaned root volumes `vol-e91af0e6c6f6782b6`, `vol-3f0bfdc43dab684de` and `vol-68a443425d1caaa23`, left behind by the three Floci launches that failed with the port-allocation error.
> **What depends on it:** nothing. Each is attached only to an already-terminated instance and holds no data.
> **Reversible?** No. There is no snapshot.
> **Effect on later labs:** none. None of these IDs appear in any `configs/*.env`.

```bash
for i in $(aws ec2 describe-instances --filters Name=instance-state-name,Values=terminated \
             --query 'Reservations[].Instances[].InstanceId' --output text); do
  for v in $(aws ec2 describe-volumes --query "Volumes[?Attachments[0].InstanceId=='$i'].VolumeId" --output text); do
    aws ec2 detach-volume --volume-id "$v" --force
    aws ec2 wait volume-available --volume-ids "$v" || sleep 3
    aws ec2 delete-volume --volume-id "$v"
  done
done
```

> [!CAUTION]
> **What will be deleted:** any Elastic IP that is not in use.
> **What depends on it:** `usms-nat-eip` *appears* unassociated in `describe-addresses` (Floci does not model the NAT gateway's association), but it **is** in use by `usms-nat`, and `usms-web-eip` is associated with `usms-web-01`. Both are KEEP.
> **Reversible?** No. A released address is gone.
> **Effect on later labs:** releasing `usms-nat-eip` would break the private tier's outbound route. **Result: nothing to release.**

```bash
# Inspected, deliberately not executed:
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].[AllocationId,Tags[?Key==`Name`]|[0].Value]' --output text
# eipalloc-a500d07735d6fa9f7  usms-nat-eip   <- in use by usms-nat; KEEP
```

### Executed result

```text
== 1. terminate usms-admin-01-host (i-f99c55305e6d3c491)
i-f99c55305e6d3c491	running	shutting-down
waiter exit 0
-- vol-e91af0e6c6f6782b6 (attached to terminated i-41b909dc38373a781)    deleted
-- vol-3f0bfdc43dab684de (attached to terminated i-20bc086530a082091)    deleted
-- vol-68a443425d1caaa23 (attached to terminated i-4c44d4349ed52e43c)    deleted
== after
vol-637fc932d3d68cd38  in-use  i-b617e94be1c24637e  usms-web-data-vol
vol-1e18b9d3e2d207ab3  in-use  i-fee3fe4304bdc1f02
vol-0973e6e59a06359fb  in-use  i-b9f5a4ea4f5a738be
vol-b2fbd2c04536b05d8  in-use  i-2e142252f014c1f12
vol-4bb9a527be88b07d3  in-use  i-b617e94be1c24637e

$ ./scripts/utilities/verify-lab-03.sh | tail -1
PASS=36  FAIL=0
```

Floci behaviours noted during the deletions:

- The admin host's root volume was deleted with it, as expected.
- The three failed-launch volumes were not, despite `DeleteOnTermination=True`.
- `detach-volume` refused with an incorrect message ("instance is running").
- `delete-volume` then deleted volumes still marked `in-use`, which real AWS refuses with `VolumeInUse`.

Nothing in Section 15's KEEP column was touched.

---

## Exercise 5 - Integration: prepare the S3 hand-off for Lab 4

**1. `labs/lab-03-ec2/transcript-upload.sh`** runs on `usms-web-01` and contains no credentials. The AWS CLI's default credential chain finds the instance profile's temporary credentials through IMDS.

```bash
#!/usr/bin/env bash
set -euo pipefail
BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"
usage() { echo "usage: $(basename "$0") <student-id> <file-path>" >&2; exit 2; }
[ $# -eq 2 ] || usage
STUDENT_ID=$1; FILE=$2
[[ "$STUDENT_ID" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: student id ... " >&2; exit 2; }
[ -f "$FILE" ] && [ -r "$FILE" ]       || { echo "error: '$FILE' is not a readable file" >&2; exit 2; }
KEY="transcripts/${STUDENT_ID}/$(basename "$FILE")"
aws s3 cp "$FILE" "s3://${BUCKET}/${KEY}" --only-show-errors
echo "uploaded s3://${BUCKET}/${KEY}"
```

```text
$ labs/lab-03-ec2/transcript-upload.sh; echo exit=$?
usage: transcript-upload.sh <student-id> <file-path>
exit=2
$ labs/lab-03-ec2/transcript-upload.sh S123 /nonexistent; echo exit=$?
error: '/nonexistent' is not a readable file
exit=2
$ grep -niE 'aws_access|secret_access|access_key' labs/lab-03-ec2/transcript-upload.sh || echo 'no credentials referenced'
no credentials referenced
```

The student ID is validated against `[A-Za-z0-9_-]` so it cannot inject `../` or extra path segments into the object key.

**2. No TCP 443 rule is needed on `usms-app-sg`.** The S3 call is an *outbound* connection from the instance. `usms-app-sg` still has the default egress rule (`IpProtocol -1` to `0.0.0.0/0`, confirmed with `describe-security-groups`), and security groups are stateful, so the reply from S3 is admitted automatically. The rule I never wrote is the default allow-all egress, and that is what makes the S3 call possible. The inbound 443 rule that exists serves HTTPS clients connecting *to* the portal, not the instance connecting out.

**3. `outputs/lab-03-s3-readiness.txt`:**

```text
# Lab 03 Exercise 5 - S3 readiness for Lab 04
# Generated 2026-10-12T18:14:10Z
instance_id        : i-b617e94be1c24637e
instance_profile   : arn:aws:iam::000000000000:instance-profile/usms-ec2-app-profile
role               : usms-ec2-app-role
attached_policy    : USMSStudentDataReadWrite
bucket_arns        : arn:aws:s3:::usms-student-data arn:aws:s3:::usms-student-data/*
bucket_name        : usms-student-data (from configs/lab-01.env)
head-bucket output :
aws: [ERROR]: An error occurred (404) when calling the HeadBucket operation: Not Found
head-bucket exit   : 254   (non-zero = bucket does not exist yet; Lab 04 Step 3 creates it)
```

The 404 (not 403) is the evidence: IAM had nothing to deny, and the bucket simply is not there. Once Lab 4 creates it, the same command from the same identity returns 200 with no change to the role, the profile or the instance.

**4. `USMS_BUCKET_NAME`** is already exported by `configs/lab-01.env` (`export USMS_BUCKET_NAME=usms-student-data`), so it was not duplicated into `configs/lab-03.env`.
