# quizcafe-terraform-bluegreen

Small GCP + Terraform portfolio sample that deploys QuizCafe as a blue/green Managed Instance Group (MIG) with a static quiz JSON hosted in a Google Cloud Storage bucket. Purpose: demonstrate IaC, GCP resources (MIG, instance template, load balancer, health checks, bucket), and a simple blue/green swap workflow.

## Architecture (high level)
- GCS bucket holds static quiz file(s).
- Two instance templates (blue / green) or one template with different metadata.
- Two Managed Instance Groups (or a single MIG using a new instance template for rolling updates).
- External HTTP Load Balancer (port 80) with backend pointing to the active MIG.
- Health check ensures only healthy group receives traffic.
- Switch traffic by updating backend service to point to the other MIG (blue ↔ green).

## Repo layout
- main.tf          — provider, global resources (bucket, networking)
- network.tf       — VPC, subnet, firewall rules
- compute.tf       — instance templates, MIGs, autoscaling
- lb.tf            — health check, backend service, forwarding rule
- variables.tf     — configurable inputs
- outputs.tf       — useful outputs (LB IP, bucket name)
- modules/         — optional modular resources
- scripts/         — startup script to fetch quiz file from GCS and run QuizCafe
- Makefile         — init/plan/apply/destroy/swap-blue/swap-green/clean targets
	- New: build-template and rolling-update targets for in-place MIG updates via gcloud
  - Note: First-time applies may briefly wait for GCP health check readiness (handled by a small Terraform sleep dependency).

## Prerequisites
- GCP project with billing enabled
- gcloud SDK and gsutil installed and authenticated
- Terraform v1.x
- Enable required APIs: compute.googleapis.com, storage.googleapis.com, iam.googleapis.com
- A service account (or use user credentials) with roles: roles/compute.admin, roles/iam.serviceAccountUser, roles/storage.admin, roles/compute.networkAdmin, roles/compute.loadBalancerAdmin

Example enable APIs:
```
gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com
```

Create service account (example):
```
gcloud iam service-accounts create tf-deployer --display-name "Terraform Deployer"
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID --member "serviceAccount:tf-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com" --role "roles/editor"
gcloud iam service-accounts keys create key.json --iam-account tf-deployer@YOUR_PROJECT_ID.iam.gserviceaccount.com
export GOOGLE_CREDENTIALS="$(cat key.json)"
## Bootstrap Project (optional)
You can create and prep a fresh project via Makefile. If you have an Organization or Folder, you may specify it; otherwise the project will be created without those flags. This repo does not destroy GCP projects.

```
# Required: PROJECT_ID, BILLING_ACCOUNT; optional: ORG_ID or FOLDER_ID
make bootstrap-project PROJECT_ID=tf-bg-quiz BILLING_ACCOUNT=AAAAAA-BBBBBB-CCCCCC
# With Org
make bootstrap-project PROJECT_ID=tf-bg-quiz ORG_ID=1234567890 BILLING_ACCOUNT=AAAAAA-BBBBBB-CCCCCC
# With Folder
make bootstrap-project PROJECT_ID=tf-bg-quiz FOLDER_ID=987654321 BILLING_ACCOUNT=AAAAAA-BBBBBB-CCCCCC

# Then deploy resources into that project
make apply PROJECT_ID=tf-bg-quiz BUCKET_NAME=quizcafe-static-unique
```

The bootstrap step creates the project, links billing, and enables required APIs. Use `make destroy` to remove workload resources; the project remains intact.
```

## Quick start (local)
1. Configure variables in `terraform.tfvars` (preferred):
```
project_id = "my-gcp-project"
region     = "us-central1"
zone       = "us-central1-a"
bucket_name = "quizcafe-static-<unique>"
machine_type = "e2-micro"
```
2. Upload quiz file to GCS:
```
gsutil mb -p $PROJECT_ID -l $REGION gs://$BUCKET_NAME
gsutil cp scripts/sample_quiz.json gs://$BUCKET_NAME/quiz.json
```
3. Terraform (via Makefile or raw commands):
```
make init
make plan
make apply

# Or raw Terraform
terraform init
terraform plan
terraform apply
```
4. Note the external IP from outputs. Verify app responds:
```
curl http://<LB_EXTERNAL_IP>/  # or /quiz depending on startup script
```

## Blue/Green deployment workflow
Option A — Two MIGs:
- Create blue and green MIGs each with their own instance template.
- Deploy new version to the inactive MIG, verify health and functionality.
- Update backend service to point to the updated MIG (swap traffic). In this repo, use Make targets:
```
make swap-green PROJECT_ID=$PROJECT_ID BUCKET_NAME=$BUCKET_NAME
# later
make swap-blue PROJECT_ID=$PROJECT_ID BUCKET_NAME=$BUCKET_NAME
```
- Optionally scale down the old MIG.

Option B — Rolling update with new instance template:
 - Build a new instance template with semantic app version (using Makefile):
```
make build-template PROJECT_ID=<id> ZONE=<zone> COLOR=<blue|green> APP_VERSION=v1.0.1
```
 - Trigger a managed rolling update for the chosen MIG:
```
make rolling-update PROJECT_ID=<id> ZONE=<zone> COLOR=<blue|green> TEMPLATE=<created-template-name>
```
 - Observe responses live via LB while instances rotate:
```
watch -n 2 'curl -s http://$(terraform output -raw lb_ip)'
```
 Response example: `Hello from <hostname> (color: green, version: v1.0.1)`
 - After confirming, swap traffic using the two-phase warm-up target:
```
make swap-green
```

Keep a health-check endpoint (e.g., /health) returning HTTP 200 for readiness checks.

### Warm-up & Zero-Downtime Swaps
- Two-phase swap in Makefile toggles `dual_backends` to route to both MIGs briefly (45s), then finalizes to a single backend.
- Prevents transient 502s during backend switch and LB health propagation.

### Observability
- `terraform output app_version` shows the active instance template-derived version.
- The app’s root `/` prints `color` and `version` from instance metadata (`color`, `app-version`).

## Variables (examples)
- project_id
- region
- zone
- bucket_name
- machine_type
- instance_count
- image (GCP image family or custom image)
- startup_script (path to startup script to run QuizCafe and fetch quiz)

## Testing & verification
- Confirm GCS file accessible from instances (startup script should `gsutil cp gs://$BUCKET/quiz.json /app/quiz.json`).
- Simulate load, verify both versions serve expected content.
- Verify health checks result in only healthy backends receiving traffic.

## Cleanup
```
make destroy PROJECT_ID=$PROJECT_ID BUCKET_NAME=$BUCKET_NAME
make clean  # remove local .terraform/ and state files
gsutil rm -r gs://$BUCKET_NAME
```

### Full Teardown (demo labs)
For quick, end-to-end teardown while keeping template safety during normal applies:
```
make destroy-all PROJECT_ID=$PROJECT_ID BUCKET_NAME=$BUCKET_NAME
```
This runs:
- `state-remove-templates` (removes instance templates from Terraform state so prevent_destroy doesn’t block)
- `destroy-safe` (destroys LB, MIGs, network, bucket, etc.)
- `destroy-templates` (deletes templates in GCP via gcloud)
- `clean` (removes local Terraform artifacts)

## Notes & best practices
- Use separate service accounts with least privilege for Terraform and instances.
- Store state securely (remote backend: GCS + state locking with Cloud Storage or use Terraform Cloud).
- Add CI/CD pipeline to automate building new instance templates and blue/green swaps.
- Monitor costs — external load balancer and instance uptime incur charges.

This README is intentionally concise; expand sections with concrete Terraform code, startup script, and CI pipeline docs for a fuller portfolio demo. HTTPS is intentionally omitted for demo simplicity; the load balancer serves HTTP on port 80.