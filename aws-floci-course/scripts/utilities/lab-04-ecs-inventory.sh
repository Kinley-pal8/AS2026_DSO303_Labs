#!/usr/bin/env bash
# ECS configuration drift report: one line per service in the USMS cluster.
# Every verdict is computed from describe-services / describe-task-definition,
# never from a service name or a tag. Also writes outputs/lab-04-ecs-inventory.json.
# Read-only; safe to run at any time, from any directory.
#
# No `set -e`: a service may legitimately lack fields (no networkConfiguration on
# an EC2 launch type service, a task definition that cannot be described), and one
# odd service must not abort the report for all the others.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
CLUSTER="${USMS_ECS_CLUSTER:-usms-ecs-cluster}"
JSON_OUT="$REPO_ROOT/outputs/lab-04-ecs-inventory.json"

# Treat empty and the CLI's literal "None" as missing.
val() { [ -n "${1:-}" ] && [ "$1" != "None" ] && echo "$1" || echo "${2:-N/A}"; }

records=()
for arn in $(aws ecs list-services --cluster "$CLUSTER" --query 'serviceArns[]' --output text 2>/dev/null); do
  IFS=$'\t' read -r name desired running taskdef publicip < <(
    aws ecs describe-services --cluster "$CLUSTER" --services "$arn" \
      --query 'services[0].[serviceName, desiredCount, runningCount, taskDefinition, networkConfiguration.awsvpcConfiguration.assignPublicIp]' \
      --output text 2>/dev/null)

  name=$(val "${name:-}" "$arn")
  desired=$(val "${desired:-}" "?")
  running=$(val "${running:-}" "?")
  # The service may hold a full ARN or (on Floci) family:revision; show family:revision.
  taskdef_short=$(val "${taskdef:-}" "N/A"); taskdef_short=${taskdef_short##*/}

  roles="N/A"
  if [ "$taskdef_short" != "N/A" ]; then
    read -r exec_arn task_arn < <(aws ecs describe-task-definition --task-definition "$taskdef_short" \
      --query 'taskDefinition.[executionRoleArn, taskRoleArn]' --output text 2>/dev/null)
    exec_arn=$(val "${exec_arn:-}" ""); task_arn=$(val "${task_arn:-}" "")
    if   [ -z "$exec_arn" ] || [ -z "$task_arn" ]; then roles="MISSING"
    elif [ "$exec_arn" = "$task_arn" ];             then roles="SAME"
    else                                                 roles="SEPARATE"
    fi
  fi

  case "$(val "${publicip:-}" "")" in
    ENABLED)  pub="RISK" ;;
    DISABLED) pub="OK" ;;
    *)        pub="N/A" ;;
  esac

  printf '%-20s desired=%-2s running=%-2s taskdef=%-18s roles=%-8s publicip=%s\n' \
    "$name" "$desired" "$running" "$taskdef_short" "$roles" "$pub"
  records+=("$(printf '{"service":"%s","desired":"%s","running":"%s","taskdef":"%s","roles":"%s","publicip":"%s"}' \
    "$name" "$desired" "$running" "$taskdef_short" "$roles" "$pub")")
done

{ printf '{"cluster":"%s","generated":"%s","services":[' "$CLUSTER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (IFS=,; printf '%s' "${records[*]:-}")
  printf ']}\n'; } | python3 -m json.tool > "$JSON_OUT"
