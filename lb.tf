// Load balancer: backend service, URL map, proxy, forwarding rule

locals {
  active_group = var.active_color == "green" ? google_compute_instance_group_manager.green.instance_group : google_compute_instance_group_manager.blue.instance_group
}

resource "google_compute_backend_service" "default" {
  name        = "quizcafe-backend"
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 10

  health_checks = [google_compute_health_check.http.self_link]

  depends_on = [
    google_compute_health_check.http,
  ]

  backend {
    group = local.active_group
  }
}

resource "google_compute_url_map" "default" {
  name            = "quizcafe-urlmap"
  default_service = google_compute_backend_service.default.self_link
}

resource "google_compute_target_http_proxy" "default" {
  name    = "quizcafe-http-proxy"
  url_map = google_compute_url_map.default.self_link
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "quizcafe-http-fr"
  target     = google_compute_target_http_proxy.default.self_link
  port_range = "80"
}
