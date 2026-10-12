#!/usr/bin/env bash
# Upload a student transcript to S3 from usms-web-01.
# Runs ON the instance. It holds no credentials: the AWS CLI finds temporary,
# auto-rotated ones from the instance profile (usms-ec2-app-profile) via IMDS.
#
# Usage: transcript-upload.sh <student-id> <file-path>
set -euo pipefail

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

usage() { echo "usage: $(basename "$0") <student-id> <file-path>" >&2; exit 2; }

[ $# -eq 2 ] || usage
STUDENT_ID=$1
FILE=$2

[[ "$STUDENT_ID" =~ ^[A-Za-z0-9_-]+$ ]] \
  || { echo "error: student id '$STUDENT_ID' must be letters, digits, '-' or '_'" >&2; exit 2; }
[ -f "$FILE" ] && [ -r "$FILE" ] \
  || { echo "error: '$FILE' is not a readable file" >&2; exit 2; }

KEY="transcripts/${STUDENT_ID}/$(basename "$FILE")"

aws s3 cp "$FILE" "s3://${BUCKET}/${KEY}" --only-show-errors
echo "uploaded s3://${BUCKET}/${KEY}"
