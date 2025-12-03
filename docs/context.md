# Project Context: QuizCafe Terraform Blue/Green

Use this doc to persist key context so Copilot Chat and teammates can quickly regain state after switching projects.

## Snapshot
- Date: 2025-12-02
- Repo: quizcafe-terraform-bluegreen
- Goal: Terraform-driven blue/green deployment for QuizCafe infrastructure

## Architecture Notes
- Environments: `blue`, `green` with controlled traffic cutover
- Provider: <aws/azure/gcp?>; Regions: <e.g., us-east-1>
- Modules: `network`, `compute`, `db`, `routing` (ALB/Ingress) — list actual module paths
- Traffic switch: <ALB target group shift / Route53 weighted DNS / service mesh>
- State backend: <S3+DynamoDB / Terraform Cloud / remote backend>
- Secrets: <SSM Parameter Store / Secrets Manager / Vault>
- CI/CD: <GitHub Actions / Azure DevOps / CircleCI>; pipelines: <path>

## Decisions & Rationale
- Deployment strategy: Blue/green with health checks and staged traffic (e.g., 10% → 50% → 100%).
- Rollback: Preserve previous color for fast revert via traffic backshift.
- Infra immutability: New ASG/instance group per color; no in-place updates.
- Database changes: <zero-downtime migration plan or read-replica strategy>.

## Open Tasks
- Validate backend state consistency and lock table.
- Confirm per-color variable files (e.g., `envs/blue.tfvars`, `envs/green.tfvars`).
- Ensure `routing` module supports weighted cutover and health-based failback.
- Add smoke tests for new color before increasing traffic.
- Document rollback runbook.

## Commands
```zsh
# initialize against the proper backend
terraform init

# plan/apply a color with isolated vars
terraform plan -var-file envs/blue.tfvars
terraform apply -var-file envs/blue.tfvars

# deploy the green color and prepare cutover
terraform plan -var-file envs/green.tfvars
terraform apply -var-file envs/green.tfvars

# Route53 example: adjust traffic weights (replace placeholders)
terraform apply -target=module.routing.aws_route53_record.color_weighted -var 'blue_weight=90' -var 'green_weight=10'

# ALB example: shift target-group weighting (if using ALB)
# terraform apply -target=module.routing.aws_lb_target_group_attachment.blue
# terraform apply -target=module.routing.aws_lb_target_group_attachment.green
```

## Helpful Links
- Runbook: `docs/runbook.md`
- Modules: `modules/`
- Pipelines: `.github/workflows/`
- Env vars: `envs/`
