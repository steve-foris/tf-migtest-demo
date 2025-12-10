// Load balancer: backend service, URL map, proxy, forwarding rule

locals {
  blue_group  = google_compute_instance_group_manager.color["blue"].instance_group
  green_group = google_compute_instance_group_manager.color["green"].instance_group

  active_group   = var.active_color == "green" ? local.green_group : local.blue_group
  inactive_group = var.active_color == "green" ? local.blue_group : local.green_group

  backend_groups = var.dual_backends ? [local.active_group, local.inactive_group] : [local.active_group]
}

// GCP health checks can be immediately creatable but not instantly "ready" for
// subsequent references. Add a delay to avoid `resourceNotReady` errors
// when creating the backend service right after the health check.
resource "time_sleep" "wait_for_hc" {
  depends_on = [
    google_compute_health_check.http,
    google_compute_instance_group_manager.color,
  ]
  create_duration = "120s"
}

resource "google_compute_backend_service" "default" {
  name        = "quizcafe-backend"
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 10

  health_checks = [google_compute_health_check.http.self_link]

  depends_on = [
    time_sleep.wait_for_hc,
  ]

  dynamic "backend" {
    for_each = local.backend_groups
    content {
      group = backend.value
    }
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
