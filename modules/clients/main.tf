data "google_compute_subnetwork" "this" {
  count   = length(var.subnets_list)
  name    = var.subnets_list[count.index]
  project = var.project_id
  region  = var.region
}

locals {
  private_nic_first_index = var.assign_public_ip ? 1 : 0
  preparation_script      = templatefile("${path.module}/init.sh", {
    yum_repo_server = var.yum_repo_server
  })

  mount_wekafs_script = templatefile("${path.module}/mount_wekafs.sh", {
    all_subnets        = split("\n",replace(join("\n", data.google_compute_subnetwork.this.*.ip_cidr_range),"/\\S+//",""))[0]
    all_gateways       = join(" ",data.google_compute_subnetwork.this.*.gateway_address)
    nics_num           = var.nics_numbers
    backend_lb_ip      = var.backend_lb_ip
    mount_clients_dpdk = var.mount_clients_dpdk
  })

  custom_data_parts = [local.preparation_script, local.mount_wekafs_script]
  vms_custom_data   = join("\n", local.custom_data_parts)
}

resource "google_compute_disk" "this" {
  count = var.clients_number
  name  = "${var.clients_name}-disk-${count.index}"
  type  = "pd-standard"
  zone  = var.zone
  size  = var.disk_size
}

resource "google_compute_instance" "this" {
  count        = var.clients_number
  name         = "${var.clients_name}-${count.index}"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = [var.clients_name]
  boot_disk {
    initialize_params {
      image = var.source_image_id
    }
  }

  // Local SSD disk
  scratch_disk {
    interface    = "NVME"
  }

  attached_disk {
    device_name = google_compute_disk.this[count.index].name
    mode        = "READ_WRITE"
    source      = google_compute_disk.this[count.index].self_link
  }

  # nic with public ip
  dynamic "network_interface" {
    for_each = range(local.private_nic_first_index)
    content {
      subnetwork = data.google_compute_subnetwork.this[network_interface.value].id
      access_config {}
    }
  }

  # nics with private ip
  dynamic "network_interface" {
    for_each = range(local.private_nic_first_index, var.nics_numbers)
    content {
      subnetwork = data.google_compute_subnetwork.this[network_interface.value].id
    }
  }

  metadata_startup_script = local.vms_custom_data

  service_account {
    email  = var.sa_email
    scopes = ["cloud-platform"]
  }
  lifecycle {
    ignore_changes = [network_interface]
  }
  depends_on = [google_compute_disk.this]
}

output "client_ips" {
  value = var.assign_public_ip ? google_compute_instance.this.*.network_interface.0.access_config.0.nat_ip :google_compute_instance.this.*.network_interface.0.network_ip
}