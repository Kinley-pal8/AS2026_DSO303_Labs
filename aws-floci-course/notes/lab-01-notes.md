# Lab 01 Notes

## Step 7 — Think about it

**Q: If `--persist` mounts a directory correctly, why is the directory almost empty in `memory` mode?**

Mounting a host directory only gives Floci a *place* to write; it does not tell Floci *to* write there. `FLOCI_STORAGE_MODE` is a separate variable that controls durability, and its default is `memory`, under which Floci keeps state in RAM and treats it as disposable — so almost nothing gets flushed to the mounted directory regardless of whether the mount itself is correct. Because Floci also assumes its own state is throwaway in this mode, it deletes the Docker volumes it created on teardown, which is why a correctly mounted directory still looks empty and a "new" volume appears on every restart.

## Step 32 — Think about it (prediction before running)

**Q: Predict the decision for `usms-audit-01` on `ec2:CreateVpc` and on `ec2:DescribeVpcs`.**

`usms-audit-01` is a member of `usms-auditors`, which has only the AWS managed `ReadOnlyAccess` policy attached — no other policy is attached to that group, and in particular the `DenyDangerousIdentityChanges` explicit-deny statement lives in `USMSDeveloperBase`, which is only attached to `usms-admins` and `usms-developers`, never to `usms-auditors`.

- `ec2:CreateVpc` → predict **implicitDeny**. `ReadOnlyAccess` grants read-only actions (`Describe*`, `Get*`, `List*` style), not create/write actions, and nothing else is attached to this user or its group to allow it. No explicit Deny applies either, since the auditor group never received that statement — so it falls through to the default deny.
- `ec2:DescribeVpcs` → predict **allowed**. `ec2:Describe*` is squarely inside what `ReadOnlyAccess` grants, and an auditor reading infrastructure state is exactly the intended use case for that managed policy.

**Actual result:** both came back `allowed` — `ec2:DescribeVpcs` as predicted, but `ec2:CreateVpc` did not (predicted `implicitDeny`).

**Why:** this Floci build's bundled `arn:aws:iam::aws:policy/ReadOnlyAccess` is not the real AWS policy. Its document is just `{"Effect":"Allow","Action":"*","Resource":"*"}` — a full-admin stub under a read-only-sounding name, not the real policy's long enumerated list of `Get*`/`List*`/`Describe*` actions. So on this emulator, the auditor group is accidentally granted everything. On real AWS, the prediction above would hold: `ec2:CreateVpc` would be `implicitDeny` and only `ec2:DescribeVpcs` would be `allowed`. This is a concrete example of the lab's "Floci Limitation" caveat — policies are stored and syntactically validated correctly, but the specific managed-policy *content* Floci ships can diverge from real AWS.
