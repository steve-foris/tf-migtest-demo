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
  default     = "e2-micro"
}

variable "instance_count" {
  description = "Number of instances per MIG"
  type        = number
  default     = 2
}

variable "max_surge" {
  description = "Default max surge for rolling updates."
  type        = number
  default     = 1
}

variable "max_unavailable" {
  description = "Default max unavailable for rolling updates."
  type        = number
  default     = 0
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

variable "active_color" {
  description = "Which environment is active: 'blue' or 'green'"
  type        = string
  default     = "blue"
  validation {
    condition     = contains(["blue", "green"], var.active_color)
    error_message = "active_color must be either 'blue' or 'green'."
  }
}

variable "dual_backends" {
  description = "When true, attach both blue and green MIGs to the backend service to warm up the inactive color before finalizing the swap."
  type        = bool
  default     = false
}

variable "prevent_destroy_templates" {
  description = "Protect instance templates from destroy; set false to allow full teardown"
  type        = bool
  default     = false
}

#We should use preemtible instances for a demo.
variable "preemptible" {
  type    = bool
  default = true
}
