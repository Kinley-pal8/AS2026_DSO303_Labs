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
