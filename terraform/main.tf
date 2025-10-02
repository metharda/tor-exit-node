# Libvirt provider
provider "libvirt" {
  uri = var.libvirt_uri
}

# SSH key generation
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh_key.private_key_pem
  filename        = "${path.module}/vm_key"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.ssh_key.public_key_openssh
  filename        = "${path.module}/vm_key.pub"
  file_permission = "0644"
}

# Create a dedicated network for the VM with NAT
resource "libvirt_network" "tor_network" {
  name      = "${var.vm_name}-network"
  mode      = "nat"
  addresses = ["192.168.100.0/24"]
  
  dhcp {
    enabled = true
  }
  
  dns {
    enabled = true
  }
  
  autostart = true
}

# Download Ubuntu 22.04 cloud image
resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-22.04-base.qcow2"
  pool   = var.storage_pool
  source = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  format = "qcow2"
}

# Create VM disk from base image
resource "libvirt_volume" "vm_disk" {
  name           = "${var.vm_name}-disk.qcow2"
  pool           = var.storage_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  size           = var.disk_size_gb * 1024 * 1024 * 1024
  format         = "qcow2"
}

# Cloud-init disk
resource "libvirt_cloudinit_disk" "cloud_init" {
  name = "${var.vm_name}-cloud-init.iso"
  pool = var.storage_pool
  
  user_data = templatefile("${path.module}/cloud-init-user-data.yml", {
    hostname        = var.vm_name
    username        = var.vm_username
    password        = var.vm_password
    ssh_public_key  = tls_private_key.ssh_key.public_key_openssh
    tailscale_key   = var.tailscale_auth_key
  })
  
  meta_data = templatefile("${path.module}/cloud-init-meta-data.yml", {
    hostname = var.vm_name
  })
}

# Create VM
resource "libvirt_domain" "vm" {
  name   = var.vm_name
  memory = var.memory_mb
  vcpu   = var.vcpu_count
  
  disk {
    volume_id = libvirt_volume.vm_disk.id
  }
  
  cloudinit = libvirt_cloudinit_disk.cloud_init.id
  
  network_interface {
    network_id     = libvirt_network.tor_network.id
    wait_for_lease = true
  }
  
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }
  
  console {
    type        = "pty"
    target_type = "virtio"
    target_port = "1"
  }
  
  graphics {
    type        = "spice"
    listen_type = "address"
    autoport    = true
  }
  
  # Enable nested virtualization for better performance
  cpu {
    mode = "host-passthrough"
  }
}

# Inventory file for Ansible
resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/../ansible/inventory.ini.tpl", {
    server_ip = libvirt_domain.vm.network_interface[0].addresses[0]
    username  = var.vm_username
    ssh_key   = local_file.private_key.filename
  })
  filename        = "${path.module}/../ansible/inventory.ini"
  file_permission = "0644"
}
