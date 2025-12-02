// Compute: instance templates (blue/green), MIGs, autoscaling

locals {
  metadata_items = [
    {
      key   = "bucket-name"
      value = var.bucket_name
    },
  ]
}

data "google_compute_image" "debian" {
  family  = split("/", var.image)[1]
  project = split("/", var.image)[0]
}

resource "google_compute_instance_template" "blue" {
  name_prefix  = "quizcafe-blue-"
  machine_type = var.machine_type

  tags = ["quizcafe-server"]

  disk {
    auto_delete  = true
    boot         = true
    source_image = data.google_compute_image.debian.self_link
  }

  scheduling {
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}
  }

  metadata_startup_script = file(var.startup_script)

  metadata = { for item in local.metadata_items : item.key => item.value }
}

resource "google_compute_instance_template" "green" {
  name_prefix  = "quizcafe-green-"
  machine_type = var.machine_type

  tags = ["quizcafe-server"]

  disk {
    auto_delete  = true
    boot         = true
    source_image = data.google_compute_image.debian.self_link
  }

  scheduling {
    preemptible         = true
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}
  }

  metadata_startup_script = file(var.startup_script)

  metadata = { for item in local.metadata_items : item.key => item.value }
}

resource "google_compute_health_check" "http" {
  name                = "quizcafe-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 80
    request_path = "/"
  }
}

resource "google_compute_instance_group_manager" "blue" {
  name               = "quizcafe-blue-mig"
  base_instance_name = "quizcafe-blue"
  zone               = var.zone
  target_size        = var.instance_count

  version {
    instance_template = google_compute_instance_template.blue.self_link
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.http.self_link
    initial_delay_sec = 60
  }
}

resource "google_compute_instance_group_manager" "green" {
  name               = "quizcafe-green-mig"
  base_instance_name = "quizcafe-green"
  zone               = var.zone
  target_size        = var.instance_count

  version {
    instance_template = google_compute_instance_template.green.self_link
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.http.self_link
    initial_delay_sec = 60
  }
}
