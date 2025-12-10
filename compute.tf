// Compute: instance templates (blue/green), MIGs, autoscaling

locals {
  # Configure blue/green MIGs + templates
  colors = {
    blue = {
      mig_name           = "migtest-blue-mig"
      base_instance_name = "migtest-blue"
    }
    green = {
      mig_name           = "migtest-green-mig"
      base_instance_name = "migtest-green"
    }
  }
}


data "google_compute_image" "debian" {
  family  = split("/", var.image)[1]
  project = split("/", var.image)[0]
}

resource "google_compute_instance_template" "app" {
  name  = "migtest-app-base"
  machine_type = var.machine_type

  tags = ["migtest-app-server"]

  disk {
    auto_delete  = true
    boot         = true
    source_image = data.google_compute_image.debian.self_link
  }

  scheduling {
    preemptible = var.preemptible

    # Preemptible: cannot auto-restart, must TERMINATE on host maintenance
    # Non-preemptible: can auto-restart, must MIGRATE on host maintenance (for e2)
    automatic_restart   = var.preemptible ? false : true
    on_host_maintenance = var.preemptible ? "TERMINATE" : "MIGRATE"
  }

  network_interface {
    network    = google_compute_network.vpc.id
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {}
  }

  metadata_startup_script = file(var.startup_script)

  lifecycle {
    # IMPORTANT: don't try to recreate the base template when the script changes.
    # Rolling updates are handled via versioned templates outside Terraform.
    ignore_changes = [
      metadata_startup_script
    ]
  }
}


resource "google_compute_health_check" "http" {
  name                = "migtest-app-hc"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 80
    request_path = "/"
  }
}

# One MIG definition, parameterised by color
resource "google_compute_instance_group_manager" "color" {
  for_each = local.colors

  name               = each.value.mig_name
  base_instance_name = each.value.base_instance_name
  zone               = var.zone
  target_size        = var.instance_count

  version {
    # Bootstrap template only – gcloud will later point this to migtest-app-vX-*
    instance_template = google_compute_instance_template.app.self_link
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.http.self_link
    initial_delay_sec = 60
  }

  lifecycle {
    # Let gcloud rolling updates change the MIG version
    ignore_changes = [version]
  }
}
