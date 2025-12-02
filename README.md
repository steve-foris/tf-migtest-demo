# quizcafe-terraform-bluegreen

Small GCP + Terraform portfolio sample that deploys QuizCafe as a blue/green Managed Instance Group (MIG) with a static quiz JSON hosted in a Google Cloud Storage bucket. Purpose: demonstrate IaC, GCP resources (MIG, instance template, load balancer, health checks, bucket), and a simple blue/green swap workflow.

## Architecture (high level)
- GCS bucket holds static quiz file(s).
- Two instance templates (blue / green) or one template with different metadata.
- Two Managed Instance Groups (or a single MIG using a new instance template for rolling updates).
- External HTTP(S) Load Balancer with backend pointing to the active MIG.
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
    apply.sh
    destroy.sh

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
```

## Quick start (local)
1. Configure variables (via terraform.tfvars or env):
```
project_id = "my-gcp-project"
region     = "us-central1"
zone       = "us-central1-a"
bucket_name = "quizcafe-static-<unique>"
machine_type = "e2-medium"
```
2. Upload quiz file to GCS:
```
gsutil mb -p $PROJECT_ID -l $REGION gs://$BUCKET_NAME
gsutil cp scripts/sample_quiz.json gs://$BUCKET_NAME/quiz.json
```
3. Terraform:
```
terraform init
terraform plan -var="project_id=$PROJECT_ID" -var="bucket_name=$BUCKET_NAME"
terraform apply -var="project_id=$PROJECT_ID" -var="bucket_name=$BUCKET_NAME"
```
4. Note the external IP from outputs. Verify app responds:
```
curl http://<LB_EXTERNAL_IP>/  # or /quiz depending on startup script
```

## Blue/Green deployment workflow
Option A — Two MIGs:
- Create blue and green MIGs each with their own instance template.
- Deploy new version to the inactive MIG, verify health and functionality.
- Update backend service to point to the updated MIG (swap traffic).
- Optionally scale down the old MIG.

Option B — Rolling update with new instance template:
- Create new instance template for the new version.
- Use MIG rolling update feature:
```
gcloud compute instance-templates create template-v2 --...
gcloud compute instance-groups managed rolling-action start-update <MIG_NAME> --version=template=template-v2 --zone=<ZONE>
```
- Monitor health checks and logs until update completes.

Keep a health-check endpoint (e.g., /health) returning HTTP 200 for readiness checks.

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
terraform destroy -var="project_id=$PROJECT_ID" -var="bucket_name=$BUCKET_NAME"
gsutil rm -r gs://$BUCKET_NAME
```

## Notes & best practices
- Use separate service accounts with least privilege for Terraform and instances.
- Store state securely (remote backend: GCS + state locking with Cloud Storage or use Terraform Cloud).
- Add CI/CD pipeline to automate building new instance templates and blue/green swaps.
- Monitor costs — external load balancer and instance uptime incur charges.

This README is intentionally concise; expand sections with concrete Terraform code, startup script, and CI pipeline docs for a fuller portfolio demo.