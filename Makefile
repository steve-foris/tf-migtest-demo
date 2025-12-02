# Simple Terraform Makefile for QuizCafe blue/green

# Variables can be overridden: make plan PROJECT_ID=... BUCKET_NAME=...
PROJECT_ID ?= $(project_id)
BUCKET_NAME ?= $(bucket_name)
REGION ?= $(region)
ZONE ?= $(zone)

TFVARS := terraform.tfvars

.PHONY: init plan apply destroy fmt validate output clean swap-blue swap-green bootstrap-project

init:
	terraform init

plan:
	@if [ -n "$(PROJECT_ID)" ]; then \
		echo "Using PROJECT_ID=$(PROJECT_ID)"; \
	fi
	@if [ -n "$(BUCKET_NAME)" ]; then \
		echo "Using BUCKET_NAME=$(BUCKET_NAME)"; \
	fi
	terraform plan $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

apply:
	terraform apply -auto-approve $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

destroy:
	terraform destroy -auto-approve $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

fmt:
	terraform fmt -recursive

validate:
	terraform validate

output:
	terraform output

clean:
	@echo "Removing local Terraform artifacts (.terraform/, tfstate, crash logs)"
	@rm -rf .terraform
	@rm -f terraform.tfstate terraform.tfstate.*
	@rm -f crash.log

swap-blue:
	@echo "Switching backend to BLUE"
	terraform apply -auto-approve -var="active_color=blue" $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

swap-green:
	@echo "Switching backend to GREEN"
	terraform apply -auto-approve -var="active_color=green" $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

bootstrap-project:
	@if [ -z "$(PROJECT_ID)" ] || [ -z "$(ORG_ID)" ] || [ -z "$(BILLING_ACCOUNT)" ]; then \
		echo "Set PROJECT_ID, ORG_ID, BILLING_ACCOUNT"; exit 1; \
	fi
	gcloud projects create "$(PROJECT_ID)" --name="QuizCafe BlueGreen" --organization="$(ORG_ID)"
	gcloud beta billing projects link "$(PROJECT_ID)" --billing-account="$(BILLING_ACCOUNT)"
	gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com --project="$(PROJECT_ID)"
