// Placeholder: configurable inputs

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "bucket_name" {
  description = "Name for the GCS bucket hosting quiz JSON"
  type        = string
}

variable "machine_type" {
  description = "Instance machine type"
  type        = string
  default     = "e2-medium"
}

variable "instance_count" {
  description = "Number of instances per MIG"
  type        = number
  default     = 2
}

variable "image" {
  description = "Base image family or custom image for instances"
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "startup_script" {
  description = "Path or content of startup script to run QuizCafe and fetch quiz"
  type        = string
  default     = "scripts/startup.sh"
}
