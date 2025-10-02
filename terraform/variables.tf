variable "libvirt_uri" {
  description = "Libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "vm_name" {
  description = "Name of the virtual machine"
  type        = string
  default     = "tailscale-tor-exit"
}

variable "vm_username" {
  description = "Username for the VM"
  type        = string
  default     = "ubuntu"
}

variable "vm_password" {
  description = "Password for the VM user"
  type        = string
  sensitive   = true
}

variable "tailscale_auth_key" {
  description = "Tailscale authentication key"
  type        = string
  sensitive   = true
}

variable "memory_mb" {
  description = "Memory size in MB"
  type        = number
  default     = 2048
}

variable "vcpu_count" {
  description = "Number of virtual CPUs"
  type        = number
  default     = 2
}

variable "disk_size_gb" {
  description = "Disk size in GB"
  type        = number
  default     = 20
}

variable "storage_pool" {
  description = "Libvirt storage pool name"
  type        = string
  default     = "default"
}

variable "network_name" {
  description = "Libvirt network name"
  type        = string
  default     = "default"
}

variable "instance_name" {
  description = "Name for the exit node configuration"
  type        = string
  default     = "tailscale-tor-exit"
}

locals {
  tags = {
    Name        = var.instance_name
    Environment = "production"
    Purpose     = "tailscale-tor-exit-node"
    Managed     = "terraform"
  }
}