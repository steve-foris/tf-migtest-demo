// Useful outputs (LB IP, bucket name)

output "bucket_name" {
  description = "QuizCafe GCS bucket"
  value       = google_storage_bucket.quiz_bucket.name
}

output "lb_ip" {
  description = "External IP of HTTP load balancer"
  value       = google_compute_global_forwarding_rule.http.ip_address
}

output "app_version" {
  description = "Active app version (instance template name based on active_color)"
  value       = var.active_color == "green" ? google_compute_instance_template.green.name : google_compute_instance_template.blue.name
}
