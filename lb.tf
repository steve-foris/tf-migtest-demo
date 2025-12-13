// Load balancer: REGIONAL external Application LB (HTTP)

locals {
  blue_group  = google_compute_instance_group_manager.color["blue"].instance_group
  green_group = google_compute_instance_group_manager.color["green"].instance_group

  active_group   = var.active_color == "green" ? local.green_group : local.blue_group
  inactive_group = var.active_color == "green" ? local.blue_group : local.green_group

  backend_groups = var.dual_backends ? [local.active_group, local.inactive_group] : [local.active_group]
}

resource "time_sleep" "wait_for_hc" {
  depends_on = [
    google_compute_region_health_check.http,
    google_compute_instance_group_manager.color,
    google_compute_subnetwork.proxy_only,
  ]
  create_duration = "120s"
}

resource "google_compute_region_backend_service" "default" {
  name                  = "migtest-app-backend"
  region                = var.region
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 10
  load_balancing_scheme = "EXTERNAL_MANAGED"

  health_checks = [google_compute_region_health_check.http.self_link]

  dynamic "backend" {
    for_each = local.backend_groups
    content {
      capacity_scaler = 1
      group = backend.value
    }
  }

  depends_on = [time_sleep.wait_for_hc]
}

resource "google_compute_region_url_map" "default" {
  name            = "migtest-app-urlmap"
  region          = var.region
  default_service = google_compute_region_backend_service.default.self_link
}

resource "google_compute_region_target_http_proxy" "default" {
  name    = "migtest-app-http-proxy"
  region  = var.region
  url_map = google_compute_region_url_map.default.self_link

  depends_on = [time_sleep.wait_for_hc]
}

resource "google_compute_forwarding_rule" "http" {
  name                  = "migtest-app-http-fr"
  region                = var.region
  load_balancing_scheme = "EXTERNAL_MANAGED"

  network = google_compute_network.vpc.self_link
  target  = google_compute_region_target_http_proxy.default.self_link

  port_range = "80"

  depends_on = [
    google_compute_subnetwork.proxy_only,   # critical
    google_compute_region_target_http_proxy.default
  ]
}