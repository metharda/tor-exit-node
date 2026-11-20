terraform {
  required_version = ">= 1.3"

  required_providers {
    # 0.9 is a rewrite with an incompatible schema.
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}
