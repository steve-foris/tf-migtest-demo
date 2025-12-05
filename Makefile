# Simple Terraform Makefile for QuizCafe blue/green
# Variables come from terraform.tfvars by default, but you can still override on the CLI:
#   make apply PROJECT_ID=... BUCKET_NAME=...

.PHONY: init plan apply destroy fmt validate output clean \
        swap-blue swap-green bootstrap-project build-template rolling-update \
        mig-status destroy-safe destroy-templates state-remove-templates destroy-all

# Attempt to read defaults from terraform.tfvars; CLI can override these.
PROJECT_ID   ?= $(shell sed -n 's/^project_id *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
BUCKET_NAME  ?= $(shell sed -n 's/^bucket_name *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
REGION       ?= $(shell sed -n 's/^region *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
ZONE         ?= $(shell sed -n 's/^zone *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)

init:
	terraform init

plan:
	@if [ -n "$(PROJECT_ID)" ]; then \
		echo "Using PROJECT_ID=$(PROJECT_ID)"; \
	fi
	@if [ -n "$(BUCKET_NAME)" ]; then \
		echo "Using BUCKET_NAME=$(BUCKET_NAME)"; \
	fi
	# Prefer terraform.tfvars; only pass -var when explicitly provided
	terraform plan \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

apply:
	# Prefer terraform.tfvars; only pass -var when explicitly provided
	terraform apply -auto-approve \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

destroy:
	# Prefer terraform.tfvars; only pass -var when explicitly provided
	terraform destroy -auto-approve \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)") \
		-var="prevent_destroy_templates=false"

fmt:
	terraform fmt -recursive

validate:
	terraform validate



destroy-safe:
	terraform destroy -auto-approve \
		-target=google_compute_global_forwarding_rule.http \
		-target=google_compute_target_http_proxy.default \
		-target=google_compute_url_map.default \
		-target=google_compute_backend_service.default \
		-target=google_compute_instance_group_manager.blue \
		-target=google_compute_instance_group_manager.green \
		-target=google_compute_health_check.http \
		-target=google_compute_firewall.allow_http \
		-target=google_compute_firewall.allow_lb_health \
		-target=google_compute_subnetwork.subnet \
		-target=google_compute_network.vpc \
		-target=google_storage_bucket.quiz_bucket \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

state-remove-templates:
	@set -e; \
	 for res in \
	   google_compute_instance_template.app \
	   google_compute_instance_template.blue \
	   google_compute_instance_template.green; do \
	   echo "Removing $$res from state (resource remains in GCP)"; \
	   terraform state rm $$res || true; \
	 done; \
	 echo "Templates removed from state. Now run: make destroy-safe PROJECT_ID=$(PROJECT_ID)"

destroy-templates:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@echo "Listing instance templates in project $(PROJECT_ID)"; \
	 names=$$(gcloud compute instance-templates list --project="$(PROJECT_ID)" --format='value(name)' | grep '^quizcafe-' || true); \
	 if [ -z "$$names" ]; then echo "No quizcafe-* templates found"; exit 0; fi; \
	 for tpl in $$names; do \
	   echo "Deleting instance template $$tpl"; \
	   gcloud compute instance-templates delete "$$tpl" --project="$(PROJECT_ID)" --quiet || true; \
	 done; \
	 echo "Template deletion complete."
	terraform validate

output:
	terraform output

clean:
	@echo "Removing local Terraform artifacts (.terraform/, tfstate, crash logs)"
	@rm -rf .terraform
	@rm -f terraform.tfstate terraform.tfstate.*
	@rm -f crash.log

# Convenience: full teardown for demo labs
# 1) Remove templates from TF state (so prevent_destroy doesn't block)
# 2) Destroy remaining infra safely via targets
# 3) Delete templates in GCP via gcloud
# 4) Clean local artifacts
destroy-all:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@echo "[destroy-all] Using PROJECT_ID=$(PROJECT_ID) BUCKET_NAME=$(BUCKET_NAME)"
	@echo "[destroy-all] Removing instance templates from Terraform state"
	$(MAKE) state-remove-templates PROJECT_ID=$(PROJECT_ID)
	@echo "[destroy-all] Destroying core infrastructure targets"
	$(MAKE) destroy-safe PROJECT_ID=$(PROJECT_ID) BUCKET_NAME=$(BUCKET_NAME)
	@echo "[destroy-all] Deleting instance templates from GCP"
	$(MAKE) destroy-templates PROJECT_ID=$(PROJECT_ID)
	@echo "[destroy-all] Cleaning local artifacts"
	$(MAKE) clean

swap-blue:
	@echo "Switching backend to BLUE"
	# Uses terraform.tfvars by default
	terraform apply -auto-approve -var="dual_backends=true" -var="active_color=blue" $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")
	@echo "Warming up BLUE for 45s" && sleep 45
	terraform apply -auto-approve -var="dual_backends=false" -var="active_color=blue" $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

swap-green:
	@echo "Switching backend to GREEN"
	# Uses terraform.tfvars by default
	terraform apply -auto-approve -var="dual_backends=true" -var="active_color=green" $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")
	@echo "Warming up GREEN for 45s" && sleep 45
	terraform apply -auto-approve -var="dual_backends=false" -var="active_color=green" $(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") $(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

bootstrap-project:
	@if [ -z "$(PROJECT_ID)" ] || [ -z "$(BILLING_ACCOUNT)" ]; then \
		echo "Set PROJECT_ID and BILLING_ACCOUNT"; exit 1; \
	fi
	gcloud projects create "$(PROJECT_ID)" --name="QuizCafe BlueGreen" $(if $(ORG_ID),--organization="$(ORG_ID)") $(if $(FOLDER_ID),--folder="$(FOLDER_ID)")
	gcloud beta billing projects link "$(PROJECT_ID)" --billing-account="$(BILLING_ACCOUNT)"
	gcloud services enable compute.googleapis.com storage.googleapis.com iam.googleapis.com --project="$(PROJECT_ID)"

# Build a new instance template with a semantic app-version and color
# Usage: make build-template COLOR=blue APP_VERSION=v1.2.3
build-template:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(COLOR)" ]; then echo "Set COLOR=blue|green"; exit 1; fi
	@if [ -z "$(APP_VERSION)" ]; then echo "Set APP_VERSION (e.g., v1.0.0)"; exit 1; fi
	@mig="quizcafe-$(COLOR)-mig"; \
	current_tpl=$$(gcloud compute instance-groups managed describe "$$mig" --project="$(PROJECT_ID)" --zone="$(ZONE)" --format='get(versions[0].instanceTemplate)'); \
	net=$$(gcloud compute instance-templates describe "$$current_tpl" --project="$(PROJECT_ID)" --format='get(properties.networkInterfaces[0].network)'); \
	sub=$$(gcloud compute instance-templates describe "$$current_tpl" --project="$(PROJECT_ID)" --format='get(properties.networkInterfaces[0].subnetwork)'); \
	echo "Creating instance template for $(COLOR) with app-version=$(APP_VERSION) on network=$$net subnet=$$sub"; \
	gcloud compute instance-templates create "quizcafe-$(COLOR)-$(shell date +%Y%m%d%H%M%S)" \
		--project="$(PROJECT_ID)" \
		--machine-type="$(or $(machine_type))" \
		--metadata=app-version="$(APP_VERSION)",bucket-name="$(or $(BUCKET_NAME),tf-bg-quiz-bucket)",color="$(COLOR)" \
		--metadata-from-file=startup-script="scripts/startup.sh" \
		--scopes=default \
		--image-project=debian-cloud --image-family=debian-12 \
		--network="$$net" --subnet="$$sub" \
		--tags=quizcafe-server

# Trigger a managed rolling update on the inactive MIG
# Usage: make rolling-update COLOR=blue|green TEMPLATE=template-name [BATCH_PERCENT=50]
rolling-update:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(COLOR)" ]; then echo "Set COLOR=blue|green"; exit 1; fi
	@if [ -z "$(TEMPLATE)" ]; then echo "Set TEMPLATE=<instance-template-name>"; exit 1; fi
	@mig="quizcafe-$(COLOR)-mig"; \
	SURGE=$(or $(MAX_SURGE),1); UNAVAIL=$(or $(MAX_UNAVAILABLE),0); \
	if [ "$$SURGE" = "0" ] && [ "$$UNAVAIL" = "0" ]; then SURGE=1; fi; \
	echo "Rolling update MIG=$$mig with template=$(TEMPLATE) (max-surge=$$SURGE, max-unavailable=$$UNAVAIL)"; \
	gcloud compute instance-groups managed rolling-action start-update "$$mig" \
		--project="$(PROJECT_ID)" --zone="$(ZONE)" \
		--type=proactive --max-unavailable=$$UNAVAIL --max-surge=$$SURGE \
		--minimal-action=replace --most-disruptive-allowed-action=replace \
		--version=template="$(TEMPLATE)"

# Show MIG rollout and per-instance status
# Usage: make mig-status COLOR=blue|green
mig-status:
	@if [ -z "$(COLOR)" ]; then echo "Set COLOR=blue|green"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@sh -c 'set -e; \
	  mig="quizcafe-$(COLOR)-mig"; \
	  echo "Status for $$mig"; \
	  gcloud compute instance-groups managed describe "$$mig" \
	    --project="$(PROJECT_ID)" --zone="$(ZONE)" \
	    --format="table(name, status.isStable, currentActions, versions)"; \
	  echo "Instances"; \
	  gcloud compute instance-groups managed list-instances "$$mig" \
	    --project="$(PROJECT_ID)" --zone="$(ZONE)" \
	    --format="table(instance, currentAction, version.targetVersion, status)" \
	'
