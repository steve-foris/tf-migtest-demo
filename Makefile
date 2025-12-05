# Simple Terraform Makefile for QuizCafe blue/green
# Variables default from terraform.tfvars, but can be overridden:
#   make apply PROJECT_ID=... BUCKET_NAME=...

.PHONY: init plan apply destroy fmt validate output clean \
        swap-blue swap-green bootstrap-project build-template \
        rolling-update mig-status wait-for-lb

# Try to read defaults from terraform.tfvars; CLI overrides still win.
BUCKET_NAME     ?= $(shell sed -n 's/^bucket_name *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
PROJECT_ID      ?= $(shell sed -n 's/^project_id *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
REGION          ?= $(shell sed -n 's/^region *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
ZONE            ?= $(shell sed -n 's/^zone *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
MACHINE_TYPE    ?= $(shell sed -n 's/^machine_type *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
MAX_SURGE       ?= $(shell sed -n 's/^max_surge *= *\([0-9][0-9]*\)/\1/p' terraform.tfvars 2>/dev/null | head -n1)
MAX_UNAVAILABLE ?= $(shell sed -n 's/^max_unavailable *= *\([0-9][0-9]*\)/\1/p' terraform.tfvars 2>/dev/null | head -n1)


init:
	terraform init

plan:
	@if [ -n "$(PROJECT_ID)" ]; then \
		echo "Using PROJECT_ID=$(PROJECT_ID)"; \
	fi
	@if [ -n "$(BUCKET_NAME)" ]; then \
		echo "Using BUCKET_NAME=$(BUCKET_NAME)"; \
	fi
	terraform plan \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

apply:
	terraform apply -auto-approve \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")
	$(MAKE) wait-for-lb

output:
	terraform output

wait-for-lb:
	@echo "Waiting for load balancer to become ready..."
	@ip=$$(terraform output -raw lb_ip 2>/dev/null || true); \
	if [ -z "$$ip" ]; then \
		echo "❌ lb_ip output not available. Did terraform apply succeed and define output \"lb_ip\"?"; \
		exit 1; \
	fi; \
	echo "Using LB IP: $$ip"; \
	for i in $$(seq 1 30); do \
	  status=$$(curl -s -o /dev/null -w "%{http_code}" http://$$ip/ || true); \
	  if [ "$$status" = "200" ]; then \
	    echo "✅ Load balancer is responding with HTTP 200 after $$i checks"; \
	    echo "Response:"; \
	    curl -s http://$$ip/ || true; \
	    echo; \
	    echo "🎉 Build complete: QuizCafe is up behind the LB."; \
	    exit 0; \
	  fi; \
	  echo "[$$i] LB not ready yet (status=$$status), waiting 10s..."; \
	  sleep 10; \
	done; \
	echo "❌ LB did not become ready within the timeout."; \
	exit 1

destroy:
	@echo "WARNING: This will destroy all Terraform-managed infrastructure in project_id=$(PROJECT_ID)"
	terraform destroy -auto-approve \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")
	$(MAKE) destroy-verify PROJECT_ID=$(PROJECT_ID)

destroy-verify:
	@echo "Verifying destruction in project: $(PROJECT_ID)"
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID=<id>"; exit 1; fi

	@echo "Checking Terraform state..."
	@if terraform state list 2>/dev/null | grep . ; then \
		echo "❌ Terraform still sees resources!"; exit 1; \
	else \
		echo "✔ Terraform state is clean."; \
	fi

	@echo "Checking GCP for leftover resources..."

	# Instances
	@if gcloud compute instances list --project=$(PROJECT_ID) --format='value(name)' | grep . ; then \
		echo "❌ Instances still exist!"; exit 1; \
	else echo "✔ No instances found."; fi

	# Instance groups
	@if gcloud compute instance-groups list --project=$(PROJECT_ID) --format='value(name)' | grep . ; then \
		echo "❌ Instance groups still exist!"; exit 1; \
	else echo "✔ No instance groups found."; fi

	# Load balancer forwarding rules
	@if gcloud compute forwarding-rules list --project=$(PROJECT_ID) --global --format='value(name)' | grep . ; then \
		echo "❌ Forwarding rules still exist!"; exit 1; \
	else echo "✔ No forwarding rules found."; fi

	# Storage buckets
	@if gsutil ls -p $(PROJECT_ID) | grep gs:// ; then \
		echo "❌ One or more buckets still exist!"; exit 1; \
	else echo "✔ No buckets found."; fi

	@echo "🎉 Destruction verified. The cloud is clean. Not even ashes remain."


fmt:
	terraform fmt -recursive

validate:
	terraform validate

clean:
	@echo "Removing local Terraform artifacts (.terraform/, tfstate, crash logs)"
	@rm -rf .terraform
	@rm -f terraform.tfstate terraform.tfstate.*
	@rm -f crash.log

# Blue/green swap with brief dual-backend warm-up.
swap-blue:
	@echo "Switching backend to BLUE (dual_backends=true warm-up, then BLUE only)"
	terraform apply -auto-approve \
		-var="dual_backends=true" \
		-var="active_color=blue" \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")
	@echo "Warming up BLUE for 45s..." && sleep 45
	terraform apply -auto-approve \
		-var="dual_backends=false" \
		-var="active_color=blue" \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

swap-green:
	@echo "Switching backend to GREEN (dual_backends=true warm-up, then GREEN only)"
	terraform apply -auto-approve \
		-var="dual_backends=true" \
		-var="active_color=green" \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")
	@echo "Warming up GREEN for 45s..." && sleep 45
	terraform apply -auto-approve \
		-var="dual_backends=false" \
		-var="active_color=green" \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \
		$(if $(BUCKET_NAME),-var="bucket_name=$(BUCKET_NAME)")

# Bootstrap a GCP project (NOT managed by Terraform)
# Usage:
#   make bootstrap-project PROJECT_ID=tf-bg-quiz BILLING_ACCOUNT=AAAAAA-BBBBBB-CCCCCC
#   [ORG_ID=...] [FOLDER_ID=...]
bootstrap-project:
	@if [ -z "$(PROJECT_ID)" ] || [ -z "$(BILLING_ACCOUNT)" ]; then \
		echo "Set PROJECT_ID and BILLING_ACCOUNT"; exit 1; \
	fi
	gcloud projects create "$(PROJECT_ID)" \
		--name="QuizCafe BlueGreen" \
		$(if $(ORG_ID),--organization="$(ORG_ID)") \
		$(if $(FOLDER_ID),--folder="$(FOLDER_ID)")
	gcloud beta billing projects link "$(PROJECT_ID)" \
		--billing-account="$(BILLING_ACCOUNT)"
	gcloud services enable \
		compute.googleapis.com \
		storage.googleapis.com \
		iam.googleapis.com \
		--project="$(PROJECT_ID)"

# Build a new instance template with app-version + color for a given MIG.
# Usage:
#   make build-template PROJECT_ID=... ZONE=us-central1-a COLOR=blue APP_VERSION=v1.2.3
build-template:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(COLOR)" ]; then echo "Set COLOR=blue|green"; exit 1; fi
	@if [ -z "$(APP_VERSION)" ]; then echo "Set APP_VERSION (e.g., v1.0.0)"; exit 1; fi
	@mig="quizcafe-$(COLOR)-mig"; \
	current_tpl=$$(gcloud compute instance-groups managed describe "$$mig" \
		--project="$(PROJECT_ID)" --zone="$(ZONE)" \
		--format='get(versions[0].instanceTemplate)'); \
	net=$$(gcloud compute instance-templates describe "$$current_tpl" \
		--project="$(PROJECT_ID)" \
		--format='get(properties.networkInterfaces[0].network)'); \
	sub=$$(gcloud compute instance-templates describe "$$current_tpl" \
		--project="$(PROJECT_ID)" \
		--format='get(properties.networkInterfaces[0].subnetwork)'); \
	new_tpl="quizcafe-$(COLOR)-$$(date +%Y%m%d%H%M%S)"; \
	echo "Creating instance template $$new_tpl for $(COLOR) with app-version=$(APP_VERSION) on network=$$net subnet=$$sub"; \
	gcloud compute instance-templates create "$$new_tpl" \
		--project="$(PROJECT_ID)" \
		--machine-type="$(MACHINE_TYPE)" \
		--metadata=app-version="$(APP_VERSION)",bucket-name="$(BUCKET_NAME)",color="$(COLOR)" \
		--metadata-from-file=startup-script="scripts/startup.sh" \
		--scopes=default \
		--image-project=debian-cloud --image-family=debian-12 \
		--network="$$net" --subnet="$$sub" \
		--tags=quizcafe-server; \
	echo "New template: $$new_tpl"

# Trigger a managed rolling update on a MIG using a given template.
# Usage:
#   make rolling-update PROJECT_ID=... ZONE=us-central1-a COLOR=blue TEMPLATE=template-name [MAX_SURGE=1 MAX_UNAVAILABLE=0]
rolling-update:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(COLOR)" ]; then echo "Set COLOR=blue|green"; exit 1; fi
	@if [ -z "$(TEMPLATE)" ]; then echo "Set TEMPLATE=<instance-template-name>"; exit 1; fi
	@mig="quizcafe-$(COLOR)-mig"; \
	echo "Rolling update MIG=$$mig with template=$(TEMPLATE) (max-surge=$(MAX_SURGE), max-unavailable=$(MAX_UNAVAILABLE))"; \
	gcloud compute instance-groups managed rolling-action start-update "$$mig" \
		--project="$(PROJECT_ID)" --zone="$(ZONE)" \
		--type=proactive \
		--max-unavailable=$(MAX_UNAVAILABLE) \
		--max-surge=$(MAX_SURGE) \
		--minimal-action=replace \
		--most-disruptive-allowed-action=replace \
		--version=template="$(TEMPLATE)"

# Show MIG and per-instance status.
# Usage:
#   make mig-status PROJECT_ID=... ZONE=us-central1-a COLOR=blue
mig-status:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(COLOR)" ]; then echo "Set COLOR=blue|green"; exit 1; fi
	@sh -c 'set -e; \
	  mig="quizcafe-$(COLOR)-mig"; \
	  echo "Status for $$mig"; \
	  gcloud compute instance-groups managed describe "$$mig" \
	    --project="$(PROJECT_ID)" --zone="$(ZONE)" \
	    --format="table(name, status.isStable, currentActions, versions)"; \
	  echo; \
	  echo "Instances:"; \
	  gcloud compute instance-groups managed list-instances "$$mig" \
	    --project="$(PROJECT_ID)" --zone="$(ZONE)" \
	    --format="table(instance, currentAction, version.targetVersion, status)" \
	'
