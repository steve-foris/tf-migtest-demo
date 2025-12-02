#!/usr/bin/env zsh
set -euo pipefail

# Apply Terraform configuration with optional variables
# Usage: PROJECT_ID=<id> BUCKET_NAME=<name> ./scripts/apply.sh

if [[ -z "${PROJECT_ID:-}" || -z "${BUCKET_NAME:-}" ]]; then
  echo "Please set PROJECT_ID and BUCKET_NAME env vars"
  exit 1
fi

terraform init
terraform plan -var="project_id=$PROJECT_ID" -var="bucket_name=$BUCKET_NAME"
terraform apply -auto-approve -var="project_id=$PROJECT_ID" -var="bucket_name=$BUCKET_NAME"
