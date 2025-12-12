# Simple Terraform Makefile for infra example blue/green GCP MIG setup
# Variables default from terraform.tfvars, but can be overridden via CLI.

.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c


.PHONY: init plan up down fmt validate output clean \
        swap-blue swap-green swap-lb bootstrap-project build-template \
        rolling-update mig-status wait-for-lb create-tfstate-bucket

# Try to read defaults from terraform.tfvars; CLI overrides still win.
PROJECT_ID      ?= $(shell sed -n 's/^project_id *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
REGION          ?= $(shell sed -n 's/^region *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
ZONE            ?= $(shell sed -n 's/^zone *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
MACHINE_TYPE    ?= $(shell sed -n 's/^machine_type *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)
MAX_SURGE       ?= $(shell sed -n 's/^max_surge *= *\([0-9][0-9]*\)/\1/p' terraform.tfvars 2>/dev/null | head -n1)
MAX_UNAVAILABLE ?= $(shell sed -n 's/^max_unavailable *= *\([0-9][0-9]*\)/\1/p' terraform.tfvars 2>/dev/null | head -n1)
PREEMPTIBLE     ?= $(shell sed -n 's/^preemptible *= *\(true\|false\)/\1/p' terraform.tfvars 2>/dev/null | head -n1)
TFSTATE_BUCKET  ?= $(shell sed -n 's/^tfstate_bucket *= *"\(.*\)"/\1/p' terraform.tfvars 2>/dev/null | head -n1)


ifeq ($(PREEMPTIBLE),true)
  PREEMPTIBLE_FLAG := --preemptible
else
  PREEMPTIBLE_FLAG :=
endif

# Ensure remote state bucket exists before terraform init
create-tfstate-bucket:
	@if [ -z "$(PROJECT_ID)" ]; then \
		echo "Set project_id in terraform.tfvars or PROJECT_ID=<id> on the CLI"; exit 1; \
	fi
	@if [ -z "$(REGION)" ]; then \
		echo "Set region in terraform.tfvars or REGION=<region> on the CLI"; exit 1; \
	fi
	@if [ -z "$(TFSTATE_BUCKET)" ]; then \
		echo 'Set tfstate_bucket in terraform.tfvars (e.g. tf-migtest-demo-tfstate)'; exit 1; \
	fi

	@echo "Ensuring Terraform state bucket gs://$(TFSTATE_BUCKET) exists in $(REGION) for project $(PROJECT_ID)..."

	@if gsutil ls -b "gs://$(TFSTATE_BUCKET)" >/dev/null 2>&1; then \
		echo "✔ Bucket gs://$(TFSTATE_BUCKET) already exists"; \
	else \
		echo "⚙ Creating bucket: gs://$(TFSTATE_BUCKET)"; \
		gsutil mb -p "$(PROJECT_ID)" -l "$(REGION)" "gs://$(TFSTATE_BUCKET)"; \
		echo "⚙ Enabling versioning on gs://$(TFSTATE_BUCKET)"; \
		gsutil versioning set on "gs://$(TFSTATE_BUCKET)"; \
	fi


init: create-tfstate-bucket
	terraform init \
      -backend-config="bucket=$(TFSTATE_BUCKET)" \
      -backend-config="prefix=tf-migtest-demo/state"

plan:
	@if [ -n "$(PROJECT_ID)" ]; then
		echo "Using PROJECT_ID=$(PROJECT_ID)"
	fi

	terraform plan \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)")

up: init
	terraform apply -auto-approve \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)")
	$(MAKE) wait-for-lb
	terraform output

output:
	terraform output

wait-for-lb:
	@echo "Waiting for load balancer to become ready..."
	ip=$$(terraform output -raw lb_ip 2>/dev/null || true)
	if [ -z "$$ip" ]; then
		echo "❌ lb_ip output not available. Did terraform apply succeed and define output \"lb_ip\"?"
		exit 1
	fi

	echo "Using LB IP: $$ip"
	for i in $$(seq 1 30); do
		status=$$(curl -s -o /dev/null -w "%{http_code}" http://$$ip/ || true)
		if [ "$$status" = "200" ]; then
			echo "✅ Load balancer is responding with HTTP 200 after $$i checks"
			echo "Response:"
			curl -s http://$$ip/ || true
			echo
			echo "🎉 Build complete: $(PROJECT_ID) is up behind the LB."
			exit 0
		fi
		echo "[$$i] LB not ready yet (status=$$status), waiting 10s..."
		sleep 10
	done

	echo "❌ LB did not become ready within the timeout."
	exit 1

down:
	@echo "WARNING: This will destroy all Terraform-managed infrastructure in project_id=$(PROJECT_ID)"
	terraform destroy -auto-approve \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)")
	$(MAKE) destroy-templates PROJECT_ID=$(PROJECT_ID)		
	$(MAKE) destroy-verify PROJECT_ID=$(PROJECT_ID)

destroy-templates:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@echo "Deleting instance templates in $(PROJECT_ID)"
	names=$$(gcloud compute instance-templates list \
		--project="$(PROJECT_ID)" \
		--format='value(name)' || true)

	if [ -z "$$names" ]; then
		echo "No $(PROJECT_ID) templates found"
	else
		for tpl in $$names; do
			echo "Deleting $$tpl"
			gcloud compute instance-templates delete "$$tpl" --project="$(PROJECT_ID)" --quiet || true
		done
	fi

destroy-verify:
	@echo "Verifying destruction in project: $(PROJECT_ID)"
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID=<id>"; exit 1; fi

	@echo "Checking Terraform state..."
	if terraform state list 2>/dev/null | grep . ; then
		echo "❌ Terraform still sees resources!"
		exit 1
	else
		echo "✔ Terraform state is clean."
	fi

	@echo "Checking GCP for leftover resources..."

	# Instances
	if gcloud compute instances list --project=$(PROJECT_ID) --format='value(name)' | grep . ; then
		echo "❌ Instances still exist!"
		exit 1
	else
		echo "✔ No instances found."
	fi

	# Instance groups
	if gcloud compute instance-groups list --project=$(PROJECT_ID) --format='value(name)' | grep . ; then
		echo "❌ Instance groups still exist!"
		exit 1
	else
		echo "✔ No instance groups found."
	fi

	# Instance templates
	if gcloud compute instance-templates list --project=$(PROJECT_ID) --format='value(name)' | grep . ; then
		echo "❌ Instance templates still exist!"
		exit 1
	else
		echo "✔ No instance templates found."
	fi

    # Load balancer forwarding rules
	if gcloud compute forwarding-rules list --project=$(PROJECT_ID) --global --format='value(name)' | grep . ; then
		echo "❌ Forwarding rules still exist!"
		exit 1
	else
		echo "✔ No forwarding rules found."
	fi

    # Storage buckets
	if gsutil ls -p $(PROJECT_ID) | grep gs:// ; then
		echo "⚠️ Buckets still exist (expected if using remote Terraform state)."
	else
		echo "✔ No buckets found."
	fi

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

swap-lb:
	@current=$$(terraform output -raw active_color 2>/dev/null || echo blue)
	@if [ "$$current" = "blue" ]; then
		new=green
	else
		new=blue
	fi

	echo "Current active color: $$current"
	echo "Switching LB to $$new (warmup phase: dual_backends=true)"

	terraform apply -auto-approve \
		-var="dual_backends=true" \
		-var="active_color=$$new" \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \

	echo "Warming up $$new for 45s..."
	sleep 45

	echo "Finalizing switch to $$new (dual_backends=false)"
	terraform apply -auto-approve \
		-var="dual_backends=false" \
		-var="active_color=$$new" \
		$(if $(PROJECT_ID),-var="project_id=$(PROJECT_ID)") \

	echo "✅ LB is now pointing at $$new"

# Bootstrap a GCP project (NOT managed by Terraform)
# Usage:
#   make bootstrap-project PROJECT_ID=tf-migtest-demo BILLING_ACCOUNT=AAAAAA-BBBBBB-CCCCCC
#   [ORG_ID=...] [FOLDER_ID=...]
bootstrap-project:
	@if [ -z "$(PROJECT_ID)" ] || [ -z "$(BILLING_ACCOUNT)" ]; then \
		echo "Set PROJECT_ID and BILLING_ACCOUNT"; exit 1; \
	fi
	gcloud projects create "$(PROJECT_ID)" \
		--name="TF MIG DEMO" \
		$(if $(ORG_ID),--organization="$(ORG_ID)") \
		$(if $(FOLDER_ID),--folder="$(FOLDER_ID)")
	gcloud beta billing projects link "$(PROJECT_ID)" \
		--billing-account="$(BILLING_ACCOUNT)"
	gcloud services enable \
		compute.googleapis.com \
		storage.googleapis.com \
		iam.googleapis.com \
		--project="$(PROJECT_ID)"

# Build a new versioned instance template for the app.
# Usage: make build-template PROJECT_ID=... APP_VERSION=v1
build-template:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(APP_VERSION)" ]; then echo "Set APP_VERSION (e.g., v1, v2.0.1)"; exit 1; fi

	name="migtest-app-$(APP_VERSION)-$$(date +%Y%m%d%H%M%S)"
	echo "Creating instance template $$name in $(PROJECT_ID)"

	# Use the existing blue MIG as the source of truth for network/subnet
	base_tpl=$$(gcloud compute instance-groups managed describe migtest-blue-mig \
	  --project="$(PROJECT_ID)" --zone="$(ZONE)" \
	  --format='value(versions[0].instanceTemplate)')
	if [ -z "$$base_tpl" ]; then
	  echo "ERROR: Could not determine base instance template from migtest-blue-mig"
	  exit 1
	fi

	net=$$(gcloud compute instance-templates describe "$$base_tpl" \
	  --project="$(PROJECT_ID)" \
	  --format='value(properties.networkInterfaces[0].network)')
	sub=$$(gcloud compute instance-templates describe "$$base_tpl" \
	  --project="$(PROJECT_ID)" \
	  --format='value(properties.networkInterfaces[0].subnetwork)')
	if [ -z "$$net" ] || [ -z "$$sub" ]; then
	  echo "ERROR: Could not determine network/subnet from $$base_tpl"
	  exit 1
	fi

	echo "DEBUG using name=$$name network=$$net subnet=$$sub machine_type=$(MACHINE_TYPE)"
	gcloud compute instance-templates create "$$name" \
	  --project="$(PROJECT_ID)" \
	  --machine-type="$(MACHINE_TYPE)" \
	  --metadata=app-version="$(APP_VERSION)" \
	  --metadata-from-file=startup-script="scripts/startup.sh" \
	  --image-project=debian-cloud --image-family=debian-12 \
	  --network="$$net" --subnet="$$sub" \
	  --tags=migtest-app-server \
	  $(PREEMPTIBLE_FLAG)
	  
	echo "Created template: $$name"
	echo "Use it with:"
	echo "  make rolling-update TEMPLATE=$$name"

# Run rolling update on the inactive MIG.
# Usage:
#   make rolling-update TEMPLATE=template-name [MAX_SURGE=1 MAX_UNAVAILABLE=0]
rolling-update:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@if [ -z "$(ZONE)" ]; then echo "Set ZONE"; exit 1; fi
	@if [ -z "$(TEMPLATE)" ]; then echo "Set TEMPLATE=<instance-template-name>"; exit 1; fi

	if [ -z "$(COLOR)" ]; then
		active=$$(terraform output -raw active_color 2>/dev/null || true)
		if [ -z "$$active" ]; then
			echo "Could not read active_color from Terraform; assuming blue as active"
			active=blue
		fi

		if [ "$$active" = "blue" ]; then
			target=green
		else
			target=blue
		fi
		echo "Detected active color=$$active; performing rolling update on INACTIVE=$$target"
	else
		target="$(COLOR)"
		echo "COLOR explicitly set to $(COLOR); performing rolling update on $$target"
	fi

	mig="migtest-$$target-mig"
	echo "Rolling update MIG=$$mig with template=$(TEMPLATE) (max-surge=$(MAX_SURGE), max-unavailable=$(MAX_UNAVAILABLE))"

	gcloud compute instance-groups managed rolling-action start-update "$$mig" \
		--project="$(PROJECT_ID)" \
		--zone="$(ZONE)" \
		--type=proactive \
		--max-unavailable=$(MAX_UNAVAILABLE) \
		--max-surge=$(MAX_SURGE) \
		--minimal-action=replace \
		--most-disruptive-allowed-action=replace \
		--version=template="$(TEMPLATE)"

# Show MIG and per-instance status.
mig-status:
	@if [ -z "$(PROJECT_ID)" ]; then echo "Set PROJECT_ID"; exit 1; fi
	@echo "=== Detecting active color via Load Balancer ==="; 
	  ip=$$(terraform output -raw lb_ip 2>/dev/null || true); 
	  if [ -z "$$ip" ]; then 
	    echo "❌ lb_ip output not available. Did terraform apply succeed?"; 
	  else \
	    resp=$$(curl -s http://$$ip/ || true); 
	    color=$$(printf '%s\n' "$$resp" | sed -n 's/.*color: \([a-zA-Z]\+\).*/\1/p'); 
	    if [ -n "$$color" ]; then \
	      echo "✅ Active color (from LB/app): $$color"; 
	    else 
	      echo "⚠ Could not parse active color from LB response."; 
	    fi; 
	    echo "LB IP: $$ip";
	    echo "LB response:";
	    printf '%s\n' "$$resp";
	  fi;
	  echo;
	  echo "=== Managed instance groups ===";
	  gcloud compute instance-groups managed list
	    --project="$(PROJECT_ID)"
	    --format='table(name:label=MIG, location:label=LOCATION, targetSize:label=TARGET_SIZE, size:label=READY, instanceTemplate:label=TEMPLATE)'
