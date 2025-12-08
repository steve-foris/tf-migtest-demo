// Compute: instance templates (blue/green), MIGs, autoscaling

locals {
  metadata_items = [
    {
      key   = "bucket-name"
      value = var.bucket_name
    },
  ]

  # Configure blue/green MIGs + templates
  colors = {
    blue = {
      name_prefix        = "quizcafe-blue-"
      mig_name           = "quizcafe-blue-mig"
      base_instance_name = "quizcafe-blue"
    }
    green = {
      name_prefix        = "quizcafe-green-"
      mig_name           = "quizcafe-green-mig"
      base_instance_name = "quizcafe-green"
    }
  }
}

data "google_compute_image" "debian" {
  family  = split("/", var.image)[1]
  project = split("/", var.image)[0]
}

# One instance template per color (blue/green)
resource "google_compute_instance_template" "color" {
  for_each    = local.colors
  name_prefix = each.value.name_prefix

  machine_type = var.machine_type
  tags         = ["quizcafe-server"]

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

  # Common metadata + per-color metadata
  metadata = merge(
    { color = each.key },
    { for item in local.metadata_items : item.key => item.value }
  )

  lifecycle {
    # Safe replacement on change
    create_before_destroy = true
  }
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

# One MIG definition, parameterised by color
resource "google_compute_instance_group_manager" "color" {
  for_each = local.colors

  name               = each.value.mig_name
  base_instance_name = each.value.base_instance_name
  zone               = var.zone
  target_size        = var.instance_count

  version {
    # initial template – Terraform's "bootstrap" truth
    instance_template = google_compute_instance_template.color[each.key].self_link
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
    # Let gcloud change the MIG's template during rolling updates
    # without Terraform trying to "fix" it back.
    ignore_changes = [version]
  }
}
