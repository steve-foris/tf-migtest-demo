// Useful outputs (LB IP, bucket name)

output "bucket_name" {
  description = "QuizCafe GCS bucket"
  value       = google_storage_bucket.quiz_bucket.name
}

output "lb_ip" {
  description = "External IP of HTTP load balancer"
  value       = google_compute_global_forwarding_rule.http.ip_address
}

output "app_template_name" {
  description = "Name of the Terraform-managed base instance template"
  value       = google_compute_instance_template.app.name
}

output "mig_templates" {
  description = "Effective instance template for each MIG"
  value = {
    blue  = google_compute_instance_group_manager.color["blue"].version[0].instance_template
    green = google_compute_instance_group_manager.color["green"].version[0].instance_template
  }
}

output "active_color" {
  description = "Currently configured active color for the load balancer"
  value       = var.active_color
}

