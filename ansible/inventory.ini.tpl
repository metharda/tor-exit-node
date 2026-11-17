[exit_nodes]
tailscale-tor-vm ansible_host=VM_IP ansible_user=VM_USERNAME ansible_ssh_private_key_file=../terraform/vm_key ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

[exit_nodes:vars]
tailscale_auth_key=TAILSCALE_AUTH_KEY
vm_hostname=VM_HOSTNAME
vm_username=VM_USERNAME
vm_memory=VM_MEMORY
vm_vcpus=VM_VCPUS