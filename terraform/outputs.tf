output "vm_ip" {
  description = "IP address of the VM"
  value       = libvirt_domain.vm.network_interface[0].addresses[0]
}

output "vm_name" {
  description = "Name of the VM"
  value       = libvirt_domain.vm.name
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key"
  value       = local_file.private_key.filename
}

output "ssh_public_key" {
  description = "SSH public key to add to your server"
  value       = tls_private_key.ssh_key.public_key_openssh
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh -i ${local_file.private_key.filename} ${var.vm_username}@${libvirt_domain.vm.network_interface[0].addresses[0]}"
}

output "ansible_inventory_path" {
  description = "Path to the generated Ansible inventory file"
  value       = local_file.ansible_inventory.filename
}

output "vm_console_command" {
  description = "Command to access VM console"
  value       = "sudo virsh console ${libvirt_domain.vm.name}"
}