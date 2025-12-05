# Terraform variable values
# Fill in with your environment specifics
project_id      = "tf-bg-quiz"
region          = "us-central1"
zone            = "us-central1-a"
bucket_name     = "tf-bg-quiz-bucket"
machine_type    = "e2-micro"
instance_count  = 2
image           = "debian-cloud/debian-12"
startup_script  = "scripts/startup.sh"
max_surge       = 1
max_unavailable = 0