#!/usr/bin/env zsh
set -euo pipefail

# Destroy Terraform resources
# Usage: PROJECT_ID=<id> BUCKET_NAME=<name> ./scripts/destroy.sh

if [[ -z "${PROJECT_ID:-}" || -z "${BUCKET_NAME:-}" ]]; then
  echo "Please set PROJECT_ID and BUCKET_NAME env vars"
  exit 1
fi

terraform destroy -auto-approve -var="project_id=$PROJECT_ID" -var="bucket_name=$BUCKET_NAME"
