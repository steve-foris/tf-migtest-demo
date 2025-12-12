# tf-migtest-demo-terraform-bluegreen

A clean, production-style GCP + Terraform blue/green Managed Instance Group (MIG) deployment demo. This project showcases:

- Infrastructure-as-Code with Terraform
- GCP Managed Instance Groups with rolling updates
- External HTTP Load Balancer with health checks
- Zero-downtime blue/green traffic switching
- Automated instance-template versioning via Makefile + gcloud
- Realistic deployment workflow similar to production systems

No buckets, no static assets - this demo focuses purely on compute + LB behavior, which keeps the architecture clean and easy to reason about.

-------------------------------------------------------------------------------

# ARCHITECTURE OVERVIEW

This project deploys:

- One Terraform-managed baseline instance template
- Two Managed Instance Groups:
    migtest-blue-mig
    migtest-green-mig
- Global HTTP Load Balancer with forwarding rule and backend service
- Health check to ensure LB only routes traffic to healthy instances
- active_color variable determines which MIG receives traffic
- Blue/green swap performed via Terraform + Makefile automation
- Rolling updates performed via gcloud using newly-built templates

This mirrors real production environments, where Terraform defines the topology and external tooling performs version rollouts.

-------------------------------------------------------------------------------

# REPO LAYOUT
.
├── main.tf                provider + global settings
├── network.tf             VPC, subnet, firewall rules
├── compute.tf             instance templates, MIG configs
├── lb.tf                  health check, backend, forwarding rule
├── variables.tf           configurable inputs
├── outputs.tf             LB IP, curl command, active_color, MIG template names
├── scripts/startup.sh     simple HTTP server (prints hostname, color, version)
├── Makefile               automation for deploy, swap, rolling updates
├── modules/               optional module stubs
└── view_gc_state.sh       A tool to monitor state of GCP resources.

# MAKEFILE FEATURES
- make init / plan / up / down / clean
- make swap-lb: smart blue/green LB switch with warm-up
- make build-template APP_VERSION=vN
- make rolling-update TEMPLATE=name
    (auto-detects active MIG; updates the inactive side)
- make bootstrap-project PROJECT_ID=... BILLING_ACCOUNT=...
    creates new GCP project, links billing, enables APIs

-------------------------------------------------------------------------------

# PREREQUISITES
- A GCP account with billing enabled
- gcloud SDK installed and authenticated
- Terraform v1.x
- Required GCP APIs:
    compute.googleapis.com
    iam.googleapis.com
- IAM permissions:
    roles/compute.admin
    roles/compute.networkAdmin
    roles/compute.loadBalancerAdmin
    roles/iam.serviceAccountUser

Enable APIs:
    gcloud services enable compute.googleapis.com iam.googleapis.com

-------------------------------------------------------------------------------

# BOOTSTRAP A FRESH PROJECT
Use Makefile to create + prepare a new project:
    make bootstrap-project PROJECT_ID=tf-migtest-demo BILLING_ACCOUNT=AAAAAA-BBBBBB-CCCCCC

This creates the project, links billing, and enables required APIs.

-------------------------------------------------------------------------------

# QUICK START

1. Configure terraform.tfvars:
project_id    = "tf-migtest-demo"
region        = "us-west1"
zone          = "us-west1-b"
machine_type  = "e2-micro"
preemptible   = true

2. Deploy:
    make init
    make plan
    make up

3. Get test command:
    terraform output curl_cmd
    or use: curl -s http://$(terraform output -raw lb_ip)

Example output:
    curl -s http://34.119.22.81

Response includes:
    Hello from <hostname> (color: blue, version: v1)

-------------------------------------------------------------------------------

BLUE/GREEN DEPLOYMENT WORKFLOW

A) Rolling Updates (gcloud-powered)

1. In a separate terminal run:
  ./view_gc_state.sh
   to observe the status.

2. Build a new instance template:
   make build-template APP_VERSION=v2
 
   This creates a uniquely timestamped template (example):
   tf-migtest-app-v2-20251211104530
 
   The make output will print a command you can use to initiate a smart rollout.

3. Update the INACTIVE MIG:
   - Smart auto-mode:
     make rolling-update TEMPLATE=<template-name>

   - Force a specific MIG:
     make rolling-update COLOR=blue TEMPLATE=<template-name>

4. Swap traffic once validated:
   make swap-lb

-------------------------------------------------------------------------------

# VERIFICATION

Show MIG + LB info:
    make mig-status

Manual curl test:
    either use ./view_gc_state.sh
    or for ip in $(gcloud compute instances list --format="value(EXTERNAL_IP)");do curl -s http://$ip;done
    This will show you the older and newer versions of the running instances.

    And to confirm LB status:
    curl -s http://$(terraform output -raw lb_ip)

-------------------------------------------------------------------------------

# CLEANUP

Destroy all Terraform-managed resources:
    make down

Remove local Terraform artifacts:
    make clean

The GCP project itself is NOT destroyed.
-------------------------------------------------------------------------------

NOTES & BEST PRACTICES

- This repo intentionally focuses on MIG + LB operations, not storage or CI/CD orchestration.
- Rolling update strategy mirrors real production patterns where Terraform is not used for per-version template swaps.
- HTTPS can be added via Google HTTPS LB for production.
- Remote Terraform state (GCS backend) recommended for team environments.
- Startup script is intentionally minimal: return hostname, color, version for visual clarity during rollouts.

-------------------------------------------------------------------------------

SUMMARY

This is a compact, production-realistic GCP Infrastructure-as-Code demo demonstrating:
- MIG blue/green deployments
- Zero-downtime LB switching
- Rolling updates with new instance templates
- Terraform + gcloud hybrid orchestration
- Clean, practical Makefile-powered workflows

