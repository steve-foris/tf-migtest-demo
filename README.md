# Terraform GCP MIG Blue/Green deployment

A clean, production-style GCP + Terraform blue/green Managed Instance Group (MIG) deployment demo.

This project showcases:
- Infrastructure-as-Code with Terraform
- GCP Managed Instance Groups with rolling updates
- External HTTP Load Balancer with health checks
- Zero-downtime blue/green traffic switching
- Automated instance-template versioning via Makefile + gcloud
- Realistic deployment workflow similar to production systems

This demo focuses purely on compute + LB behavior, which keeps the architecture clean and easy to reason about.
It also keeps best practices in mind and keeping costs low.

-------------------------------------------------------------------------------

# ARCHITECTURE OVERVIEW

This project deploys:
- One Terraform-managed baseline instance template
- Two Managed Instance Groups:
    migtest-blue-mig
    migtest-green-mig
- Regional external Application Load Balancer
- Health check to ensure LB only routes traffic to healthy instances
- active_color variable determines which MIG receives traffic
- Blue/green swap performed via Terraform + Makefile automation
- Rolling updates performed via gcloud using newly-built templates

This mirrors real production environments, where Terraform defines the topology and external tooling performs version rollouts.

-------------------------------------------------------------------------------

# REPO LAYOUT
```text
.
├── main.tf                — provider & global settings (provider config, project/region defaults, service accounts)
├── network.tf             — VPC, subnet, routes, and firewall rules used by MIGs and LB
├── compute.tf             — instance templates, managed instance group (MIG) definitions for blue & green
├── lb.tf                  — health check, backend service, backend buckets/groups, forwarding rule (HTTP LB)
├── variables.tf           — input variables and defaults for project, region, sizes, colors, etc.
├── outputs.tf             — exposed outputs: LB IP, curl command, active_color, MIG/template names
├── terraform.tfvars       — example variable values (project_id, zone, machine_type, preemptible, ...)
├── Makefile               — automation for init/plan/up/down, build-template, rolling-update, swap-lb, bootstrap
├── README.md              — repo overview, architecture, quickstart, workflow, and cleanup instructions
├── scripts/
│   └── startup.sh         — simple HTTP server startup script (prints hostname, color, version)
├── modules/
│   └── README.md          — module stubs, usage notes and extension guidance
└── utils/
    ├── gcp_audit.sh       — helper to audit/collect basic GCP resource info
    └── view_gc_state.sh   — real-time helper to monitor MIG/LB instance state during rollouts

# MAKEFILE FEATURES
- make init / plan / up / down / clean
- make swap-lb: smart blue/green LB switch with warm-up
- make build-template APP_VERSION=vN
- make rolling-update TEMPLATE=name
    (auto-detects active MIG; updates the inactive side)
- make bootstrap-project PROJECT_ID=... BILLING_ACCOUNT=...
    creates new GCP project, links billing, enables APIs
```
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
```shell
    gcloud services enable compute.googleapis.com iam.googleapis.com
```
-------------------------------------------------------------------------------

# BOOTSTRAP A FRESH PROJECT
Use Makefile to create + prepare a new project:
```shell
    make bootstrap-project PROJECT_ID=tf-migtest-demo BILLING_ACCOUNT=AAAAAA-BBBBBB-CCCCCC
```
This creates the project, links billing, and enables required APIs.

-------------------------------------------------------------------------------

# QUICK START
After bootstrap step above.
```text
1. Configure terraform.tfvars:
project_id    = "tf-migtest-demo"
region        = "us-central1"
zone          = "us-central1-a"
machine_type  = "e2-micro"
preemptible   = true
```
2. Deploy:
```shell
    make init
    make plan
    make up
```

3. Get test command:
```shell
    terraform output curl_cmd
    or use: 
    curl -s http://$(terraform output -raw lb_ip)
```

Example output:
```shell
    curl -s http://34.119.22.81
```
Response includes:
```shell
    Hello from <hostname> (color: blue, version: v1)
```
-------------------------------------------------------------------------------

# BLUE/GREEN DEPLOYMENT WORKFLOW
```text
Rolling Updates (gcloud-powered)

1. To observe the status, in a separate terminal run:
   utils/view_gc_state.sh

2. Build a new instance template:
   make build-template APP_VERSION=v2
 
   This creates a uniquely timestamped template (example):
   tf-migtest-app-v2-20251211104530
 
   The make output will print a command you can use to initiate a smart rollout.

3. Update the INACTIVE MIG:
   - Smart auto-mode (recommended):
     make rolling-update TEMPLATE=<template-name>

   - Force a specific MIG:
     make rolling-update COLOR=blue TEMPLATE=<template-name>

4. Swap traffic once validated:
   make swap-lb
```
-------------------------------------------------------------------------------

# VERIFICATION
```text
Show MIG + LB info:
    make mig-status

Manual curl test:
    either use ./view_gc_state.sh
    or for ip in $(gcloud compute instances list --format="value(EXTERNAL_IP)");do curl -s http://$ip;done
    This will show you the older and newer versions of the running instances.

    And to confirm LB status:
    curl -s http://$(terraform output -raw lb_ip)
```
-------------------------------------------------------------------------------

# CLEANUP
Destroy all Terraform-managed resources:
```shell
    make down
```

Remove local Terraform artifacts:
```shell
    make clean
```

You can also verify what billable objects may still be in the project with.
```shell
utils/gcp_audit.sh
```

The GCP project itself is NOT destroyed.
-------------------------------------------------------------------------------

NOTES & BEST PRACTICES

- This repo intentionally focuses on MIG + LB operations, not storage or CI/CD orchestration.
- Rolling update strategy mirrors real production patterns where Terraform is not used for per-version template swaps.
- HTTPS can be added via Google HTTPS LB for production.
- Remote Terraform state (GCS backend) recommended for team environments.
- Startup script is intentionally minimal: return hostname, color, version for visual clarity during rollouts.
- No CI/CD is involved — this repo focuses on infrastructure behavior, not pipelines.
- Load balancer switching is handled declaratively via Terraform, orchestrated by Make.
- Designed for short-lived demos and testing, don’t leave it running unattended.

-------------------------------------------------------------------------------

SUMMARY

This is a compact, production-realistic GCP Infrastructure-as-Code demo demonstrating:
- MIG blue/green deployments
- Zero-downtime LB switching
- Rolling updates with new instance templates
- Terraform + gcloud hybrid orchestration
- Clean, practical Makefile-powered workflows
-------------------------------------------------------------------------------
