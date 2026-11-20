provider "libvirt" {
  uri = var.libvirt_uri
}

# SSH key used by Ansible and `make ssh`.
resource "tls_private_key" "ssh_key" {
  algorithm = "ED25519"
}

resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ssh_key.private_key_openssh
  filename        = "${path.module}/vm_key"
  file_permission = "0600"
}

# Dedicated storage pool and NAT network, so the deployment neither depends on
# nor modifies the host's existing libvirt pools and networks.
resource "libvirt_pool" "pool" {
  name = "${var.vm_name}-pool"
  type = "dir"
  target {
    path = "${var.pool_path}/${var.vm_name}"
  }
}

resource "libvirt_network" "network" {
  name      = "${var.vm_name}-net"
  mode      = "nat"
  addresses = [var.network_cidr]
  autostart = true

  dhcp {
    enabled = true
  }

  dns {
    enabled = true
  }
}

resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-22.04-base.qcow2"
  pool   = libvirt_pool.pool.name
  source = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  format = "qcow2"
}

resource "libvirt_volume" "vm_disk" {
  name           = "${var.vm_name}-disk.qcow2"
  pool           = libvirt_pool.pool.name
  base_volume_id = libvirt_volume.ubuntu_base.id
  size           = var.disk_size_gb * 1024 * 1024 * 1024
  format         = "qcow2"
}

resource "libvirt_cloudinit_disk" "cloud_init" {
  name = "${var.vm_name}-cloud-init.iso"
  pool = libvirt_pool.pool.name

  user_data = templatefile("${path.module}/cloud-init-user-data.yml", {
    hostname       = var.vm_name
    username       = var.vm_username
    password       = var.vm_password
    ssh_public_key = tls_private_key.ssh_key.public_key_openssh
  })

  meta_data = templatefile("${path.module}/cloud-init-meta-data.yml", {
    hostname = var.vm_name
  })
}

resource "libvirt_domain" "vm" {
  name      = var.vm_name
  memory    = var.memory_mb
  vcpu      = var.vcpu_count
  autostart = true

  cloudinit = libvirt_cloudinit_disk.cloud_init.id

  cpu {
    mode = "host-passthrough"
  }

  # Attached by path (a dir-pool volume's id is its path) rather than as a pool
  # volume: on AppArmor hosts (Debian, Ubuntu) libvirt's profile helper cannot
  # resolve pool volumes, so qemu would be denied the disk and its backing image.
  disk {
    file = libvirt_volume.vm_disk.id
  }

  xml {
    xslt = file("${path.module}/disk-driver.xsl")
  }

  network_interface {
    network_id     = libvirt_network.network.id
    wait_for_lease = true
  }

  # Serial console for `virsh console` (log in with the VM password).
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/../ansible/inventory.ini.tpl", {
    vm_name  = var.vm_name
    vm_ip    = libvirt_domain.vm.network_interface[0].addresses[0]
    username = var.vm_username
    ssh_key  = abspath(local_sensitive_file.private_key.filename)
  })
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"
}
