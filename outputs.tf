// Useful outputs (LB IP, bucket name)

output "bucket_name" {
  description = "QuizCafe GCS bucket"
  value       = google_storage_bucket.quiz_bucket.name
}

output "lb_ip" {
  description = "External IP of HTTP load balancer"
  value       = google_compute_global_forwarding_rule.http.ip_address
}
