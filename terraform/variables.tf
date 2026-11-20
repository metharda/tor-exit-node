variable "libvirt_uri" {
  description = "Libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "vm_name" {
  description = "Name of the VM; also prefixes its libvirt pool and network"
  type        = string
  default     = "tailscale-tor-exit"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,40}$", var.vm_name))
    error_message = "Use lowercase letters, digits and dashes (max 41 characters)."
  }
}

variable "vm_username" {
  description = "Login user created in the VM"
  type        = string
  default     = "ubuntu"
}

variable "vm_password" {
  description = "Password for the VM user (console login only; SSH is key-only)"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.vm_password) >= 8
    error_message = "The VM password must be at least 8 characters."
  }
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

variable "pool_path" {
  description = "Host directory in which the VM's storage pool directory is created"
  type        = string
  default     = "/var/lib/libvirt/images"
}

variable "network_cidr" {
  description = "Subnet of the VM's private NAT network; must not overlap host networks"
  type        = string
  default     = "192.168.100.0/24"
}
