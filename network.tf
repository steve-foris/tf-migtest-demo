// Network: VPC, subnetwork, firewall rules

resource "google_compute_network" "vpc" {
  name                    = "quizcafe-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "quizcafe-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_firewall" "allow_http" {
  name    = "quizcafe-allow-http"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  direction   = "INGRESS"
  target_tags = ["quizcafe-server"]
  source_ranges = [
    "0.0.0.0/0",
  ]
}
