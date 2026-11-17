[exit_nodes]
tailscale-tor-vm ansible_host=${vm_ip} ansible_user=${vm_username} ansible_ssh_private_key_file=../terraform/vm_key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

[exit_nodes:vars]
vm_hostname=${vm_hostname}
vm_username=${vm_username}
vm_memory=${vm_memory}
vm_vcpus=${vm_vcpus}
