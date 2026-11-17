#!/bin/bash

set -euo pipefail

# Get absolute path to project root
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly TERRAFORM_DIR="$PROJECT_ROOT/terraform"
readonly ANSIBLE_DIR="$PROJECT_ROOT/ansible"
readonly SCRIPTS_DIR="$PROJECT_ROOT/scripts"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() {
	echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
	echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
	echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_dependencies() {
	log_info "Checking dependencies..."
	if ! "$SCRIPTS_DIR/check-dependencies.sh"; then
		log_error "Dependencies check failed"
		log_info "Run 'make install-deps' to install missing dependencies"
		exit 1
	fi
}

check_pre_deployment() {
	log_info "Running pre-deployment checks..."

	if [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]] && [[ -s "$TERRAFORM_DIR/terraform.tfstate" ]]; then
		log_warn "Existing Terraform state found"
		read -r -p "Infrastructure may already be deployed. Continue anyway? (y/N): " continue_deploy
		if [[ "$continue_deploy" != "y" && "$continue_deploy" != "Y" ]]; then
			log_info "Deployment cancelled by user"
			log_info "Use 'make destroy' to remove existing infrastructure first"
			exit 0
		fi
	fi

	log_info "Checking code formatting..."
	if ! "$SCRIPTS_DIR/format-check.sh" --check; then
		log_warn "Code formatting issues found"
		read -r -p "Auto-fix formatting issues? (Y/n): " fix_format
		if [[ "$fix_format" != "n" && "$fix_format" != "N" ]]; then
			"$SCRIPTS_DIR/format-check.sh" --fix
			log_success "Formatting issues fixed"
		else
			log_warn "Proceeding with formatting issues"
		fi
	fi
}

collect_user_input() {
	log_info "Collecting deployment configuration..."
	echo

	read -r -p "Enter VM name [$USER-tailscale-tor]: " VM_NAME
	VM_NAME="${VM_NAME:-$USER-tailscale-tor}"
	if [[ ! "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
		log_error "VM name may only contain letters, digits and '-'"
		exit 1
	fi

	read -r -p "Enter username for the VM [ubuntu]: " VM_USERNAME
	VM_USERNAME="${VM_USERNAME:-ubuntu}"

	while true; do
		read -rs -p "Enter password for VM user ($VM_USERNAME): " VM_PASSWORD
		echo
		if [[ -z "$VM_PASSWORD" ]]; then
			log_warn "Password cannot be empty"
			continue
		fi
		if [[ ${#VM_PASSWORD} -lt 8 ]]; then
			log_warn "Password must be at least 8 characters long"
			continue
		fi
		read -rs -p "Confirm password: " VM_PASSWORD_CONFIRM
		echo
		if [[ "$VM_PASSWORD" != "$VM_PASSWORD_CONFIRM" ]]; then
			log_warn "Passwords do not match, please try again"
			continue
		fi
		break
	done

	echo
	echo "=== Tailscale Auth Key Required ==="
	echo "You need a Tailscale auth key to connect the VM to your tailnet."
	echo
	echo "1. Go to: https://login.tailscale.com/admin/settings/keys"
	echo "2. Click 'Generate auth key'"
	echo "3. Settings recommended:"
	echo "   ✓ Reusable: Yes (in case deployment fails and needs retry)"
	echo "   ✓ Ephemeral: No (so the device stays in your tailnet)"
	echo "   ✓ Tags: Optional (e.g., tag:exit-node)"
	echo
	echo "Auth key format: tskey-auth-k..."
	echo "Example: tskey-auth-kABCDEF123-GJKLMNOP456QRSTUVWXYZ789abcdefghijklmnop"
	echo
	
	while true; do
		read -rs -p "Enter Tailscale auth key: " TAILSCALE_AUTH_KEY
		echo
		if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
			log_warn "Tailscale auth key cannot be empty"
			continue
		fi
		
		# Basic format validation
		if [[ ! "$TAILSCALE_AUTH_KEY" =~ ^tskey-auth- ]]; then
			log_warn "Invalid auth key format. It should start with 'tskey-auth-'"
			echo "Expected format: tskey-auth-k..."
			continue
		fi
		
		if [[ ${#TAILSCALE_AUTH_KEY} -lt 25 ]]; then
			log_warn "Auth key seems too short. Please check and try again."
			continue
		fi
		
		log_success "Auth key format looks valid"
		break
	done

	echo
	read -r -p "Enter memory size in MB [2048]: " MEMORY_MB
	MEMORY_MB="${MEMORY_MB:-2048}"

	read -r -p "Enter number of CPUs [2]: " VCPU_COUNT
	VCPU_COUNT="${VCPU_COUNT:-2}"

	read -r -p "Enter disk size in GB [20]: " DISK_SIZE_GB
	DISK_SIZE_GB="${DISK_SIZE_GB:-20}"

	local value
	for value in "$MEMORY_MB" "$VCPU_COUNT" "$DISK_SIZE_GB"; do
		if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
			log_error "Memory, CPU count and disk size must be positive whole numbers (got '$value')"
			exit 1
		fi
	done

	echo
	log_info "Configuration collected successfully"
	
	# Storage pool and subnet are variables; nothing assumes a pool called
	# "default" or "images". STORAGE_POOL / VM_NETWORK may be preset in the environment.
	read -r -p "Enter libvirt storage pool [${STORAGE_POOL:-}]: " pool_input
	STORAGE_POOL="${pool_input:-${STORAGE_POOL:-}}"
	if [[ -z "$STORAGE_POOL" ]] || ! sudo virsh pool-info "$STORAGE_POOL" >/dev/null 2>&1; then
		log_error "Storage pool '${STORAGE_POOL}' not found (see: sudo virsh pool-list --all)"
		exit 1
	fi
	if ! sudo virsh pool-info "$STORAGE_POOL" | grep -q "State:.*running"; then
		log_error "Storage pool '$STORAGE_POOL' is not running (sudo virsh pool-start $STORAGE_POOL)"
		exit 1
	fi

	read -r -p "Enter VM network subnet [${VM_NETWORK:-192.168.100.0/24}]: " network_input
	VM_NETWORK="${network_input:-${VM_NETWORK:-192.168.100.0/24}}"
	if [[ ! "$VM_NETWORK" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
		log_error "VM network must be an IPv4 CIDR such as 192.168.100.0/24"
		exit 1
	fi

	# The deployed (non-secret) values are kept next to the state, so destroy.sh
	# runs Terraform with exactly the variables this deployment used.
	(
		umask 077
		cat >"$TERRAFORM_DIR/deploy.auto.tfvars.json" <<EOF
{
  "vm_name": "$VM_NAME",
  "vm_username": "$VM_USERNAME",
  "memory_mb": $MEMORY_MB,
  "vcpu_count": $VCPU_COUNT,
  "disk_size_gb": $DISK_SIZE_GB,
  "storage_pool": "$STORAGE_POOL",
  "vm_network": "$VM_NETWORK"
}
EOF
	)
	export TF_VAR_vm_password="$VM_PASSWORD"
}

check_network_free() {
	log_info "Checking that $VM_NETWORK is free..."

	local net
	for net in $(sudo virsh net-list --all --name); do
		[[ "$net" == "$VM_NAME-network" ]] && continue
		if sudo virsh net-dumpxml "$net" | python3 -c '
import ipaddress, sys, xml.etree.ElementTree as ET
want = ipaddress.ip_network(sys.argv[1], strict=False)
for ip in ET.parse(sys.stdin).iter("ip"):
    mask = ip.get("prefix") or ip.get("netmask")
    if ip.get("family", "ipv4") == "ipv4" and ip.get("address") and mask:
        if want.overlaps(ipaddress.ip_interface(ip.get("address") + "/" + mask).network):
            sys.exit(0)
sys.exit(1)' "$VM_NETWORK"; then
			log_error "Libvirt network '$net' already uses $VM_NETWORK; refusing to deploy"
			exit 1
		fi
	done

	if ! sudo virsh net-info "$VM_NAME-network" >/dev/null 2>&1 &&
		[[ -n "$(ip -4 route show "$VM_NETWORK")" ]]; then
		log_error "$VM_NETWORK is already routed on this host; refusing to deploy"
		exit 1
	fi
}

check_libvirt() {
	log_info "Checking libvirt/KVM setup..."
	
	if ! command -v virsh >/dev/null 2>&1; then
		log_error "virsh not found. Please install libvirt-daemon-system and libvirt-clients"
		echo "On Ubuntu/Debian: sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils"
		exit 1
	fi

	if ! sudo virsh list >/dev/null 2>&1; then
		log_error "Cannot connect to libvirt. Please ensure libvirtd is running and you have permissions"
		echo "Try: sudo systemctl start libvirtd"
		echo "Add user to libvirt group: sudo usermod -a -G libvirt $USER"
		exit 1
	fi

	log_success "Libvirt setup verified"
}

run_terraform() {
	log_info "Initializing and applying Terraform configuration..."

	cd "$TERRAFORM_DIR"

	terraform init
	terraform validate

	if ! terraform plan -out=tfplan; then
		log_error "Terraform planning failed"
		exit 1
	fi

	if ! terraform apply tfplan; then
		rm -f tfplan
		log_error "Terraform apply failed"
		exit 1
	fi
	rm -f tfplan

	log_success "Infrastructure provisioned successfully"
}

check_ansible_inventory() {
	# terraform/main.tf renders ansible/inventory.ini.tpl; there is no second renderer.
	if [[ ! -s "$ANSIBLE_DIR/inventory.ini" ]]; then
		log_error "Ansible inventory was not generated by Terraform: $ANSIBLE_DIR/inventory.ini"
		exit 1
	fi
	chmod 600 "$ANSIBLE_DIR/inventory.ini" "$TERRAFORM_DIR/vm_key"
	log_success "Ansible inventory ready"
}

wait_for_ssh() {
	log_info "Waiting for VM to boot and SSH to be available..."

	local vm_ip
	if [[ ! -d "$TERRAFORM_DIR" ]]; then
		log_error "Terraform directory not found: $TERRAFORM_DIR"
		exit 1
	fi
	
	vm_ip=$(cd "$TERRAFORM_DIR" && terraform output -raw vm_ip 2>/dev/null)
	local max_attempts=120  # Increased from 60 to 120 (20 minutes)
	local attempt=1

	if [[ -z "$vm_ip" ]]; then
		log_error "Could not retrieve VM IP from Terraform"
		exit 1
	fi

	log_info "Attempting SSH connection to VM at $vm_ip"
	log_info "This may take several minutes while cloud-init completes..."

	while [[ $attempt -le $max_attempts ]]; do
		if ssh -i "$TERRAFORM_DIR/vm_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "$VM_USERNAME@$vm_ip" "echo 'SSH OK'" &>/dev/null; then
			log_success "SSH connectivity established to $vm_ip"
			
			# Wait for cloud-init to complete
			log_info "Waiting for cloud-init to complete..."
			local cloud_init_attempts=60
			local cloud_init_attempt=1
			
			while [[ $cloud_init_attempt -le $cloud_init_attempts ]]; do
				if ssh -i "$TERRAFORM_DIR/vm_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$VM_USERNAME@$vm_ip" "test -f /var/lib/cloud/instance/boot-finished" &>/dev/null; then
					log_success "Cloud-init initialization completed"
					return 0
				fi
				
				log_info "Cloud-init attempt $cloud_init_attempt/$cloud_init_attempts: Still initializing..."
				sleep 15
				((cloud_init_attempt++))
			done
			
			log_warn "Cloud-init timeout, but proceeding anyway"
			return 0
		fi

		log_info "Attempt $attempt/$max_attempts: SSH not ready, waiting 10 seconds..."
		sleep 10
		((attempt++))
	done

	log_error "SSH connectivity timeout"
	log_info "Try manually: ssh -i $TERRAFORM_DIR/vm_key $VM_USERNAME@$vm_ip"
	exit 1
}

run_ansible() {
	log_info "Running Ansible playbook..."

	cd "$ANSIBLE_DIR"

	# The auth key reaches Ansible through the environment only; it is not
	# written to the inventory, the cloud-init disk or the Terraform state.
	if ! TAILSCALE_AUTH_KEY="$TAILSCALE_AUTH_KEY" ansible-playbook -i inventory.ini playbook.yml; then
		log_error "Ansible playbook failed"
		exit 1
	fi

	log_success "Configuration completed successfully"
}

display_results() {
	log_success "Deployment completed successfully!"
	echo

	local vm_ip
	if [[ -d "$TERRAFORM_DIR" ]]; then
		vm_ip=$(cd "$TERRAFORM_DIR" && terraform output -raw vm_ip 2>/dev/null)
	else
		log_error "Terraform directory not found: $TERRAFORM_DIR"
		return 1
	fi

	echo "=== KVM VM Information ==="
	echo "VM Name: $VM_NAME"
	echo "VM IP: $vm_ip"
	echo "VM User: $VM_USERNAME"
	echo "VM Memory: ${MEMORY_MB}MB"
	echo "VM CPUs: $VCPU_COUNT"
	echo "SSH Command: ssh -i $TERRAFORM_DIR/vm_key $VM_USERNAME@$vm_ip"
	echo

	echo "=== Next Steps ==="
	echo "1. Authorize the exit node in Tailscale admin: https://login.tailscale.com/admin/machines"
	echo "2. On a client device, connect via: tailscale up --exit-node=<tailscale-ip>"
	echo "3. Test Tor routing: curl https://check.torproject.org"
	echo "4. Verify no leaks: make verify"
	echo

	echo "=== Verification Commands ==="
	echo "Check Tailscale status: ssh -i $TERRAFORM_DIR/vm_key $VM_USERNAME@$vm_ip 'sudo tailscale status'"
	echo "Check Tor container: ssh -i $TERRAFORM_DIR/vm_key $VM_USERNAME@$vm_ip 'sudo docker logs tor-proxy'"
	echo "Check transparent proxy: ssh -i $TERRAFORM_DIR/vm_key $VM_USERNAME@$vm_ip 'sudo systemctl status transparent-proxy'"
	echo "Check iptables rules: ssh -i $TERRAFORM_DIR/vm_key $VM_USERNAME@$vm_ip 'sudo iptables -t nat -L -n -v'"
	echo "Test Tor IP: ssh -i $TERRAFORM_DIR/vm_key $VM_USERNAME@$vm_ip 'curl -s https://ipinfo.io/ip'"
}

cleanup_on_error() {
	log_error "Deployment failed, cleaning up..."
	cd "$TERRAFORM_DIR" 2>/dev/null && terraform destroy -auto-approve 2>/dev/null || true
	rm -f "$ANSIBLE_DIR/inventory.ini" 2>/dev/null || true
}

main() {
	log_info "Starting Tailscale Tor Exit Node deployment with KVM/libvirt"

	trap cleanup_on_error ERR

	check_dependencies
	check_pre_deployment
	check_libvirt
	collect_user_input
	check_network_free
	run_terraform
	check_ansible_inventory
	wait_for_ssh
	run_ansible
	display_results

	log_success "All deployment steps completed successfully"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
