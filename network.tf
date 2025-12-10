// Network: VPC, subnetwork, firewall rules

resource "google_compute_network" "vpc" {
  name                    = "migtest-app-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "migtest-app-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_firewall" "allow_http" {
  name    = "migtest-app-allow-http"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  direction   = "INGRESS"
  target_tags = ["migtest-app-server"]
  source_ranges = [
    "0.0.0.0/0",
  ]
}

resource "google_compute_firewall" "allow_lb_health" {
  name    = "migtest-app-allow-lb-health"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  direction   = "INGRESS"
  target_tags = ["migtest-app-server"]
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]
}
