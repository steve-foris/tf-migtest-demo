# Terraform variable values
# Fill in with your environment specifics
project_id      = "tf-migtest-demo"
region          = "us-central1"
zone            = "us-central1-a"
machine_type    = "e2-micro"
instance_count  = 2
image           = "debian-cloud/debian-12"
startup_script  = "scripts/startup.sh"
max_surge       = 0
max_unavailable = 1
preemptible = false
tfstate_bucket = "tf-migtest-demo-tfstate"