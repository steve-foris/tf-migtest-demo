// Placeholder: provider and global resources will be defined here.
terraform {
  required_version = ">= 1.0.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# Global resources

# Quiz bucket for hosting static quiz JSON
resource "google_storage_bucket" "quiz_bucket" {
  name                        = var.bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}

# Optional: grant public read to objects (commented by default)
# resource "google_storage_bucket_iam_binding" "public_read" {
#   bucket = google_storage_bucket.quiz_bucket.name
#   role   = "roles/storage.objectViewer"
#   members = [
#     "allUsers",
#   ]
# }
