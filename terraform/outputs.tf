output "vm_ip" {
  description = "IP address of the VM on its private libvirt network"
  value       = libvirt_domain.vm.network_interface[0].addresses[0]
}

output "vm_name" {
  description = "Name of the VM"
  value       = libvirt_domain.vm.name
}

output "vm_username" {
  description = "Login user in the VM"
  value       = var.vm_username
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh -i ${abspath(local_sensitive_file.private_key.filename)} ${var.vm_username}@${libvirt_domain.vm.network_interface[0].addresses[0]}"
}

output "console_command" {
  description = "Serial console of the VM"
  value       = "sudo virsh console ${libvirt_domain.vm.name}"
}
