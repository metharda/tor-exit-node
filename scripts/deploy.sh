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
		read -p "Infrastructure may already be deployed. Continue anyway? (y/N): " continue_deploy
		if [[ "$continue_deploy" != "y" && "$continue_deploy" != "Y" ]]; then
			log_info "Deployment cancelled by user"
			log_info "Use 'make destroy' to remove existing infrastructure first"
			exit 0
		fi
	fi

	log_info "Checking code formatting..."
	if ! "$SCRIPTS_DIR/format-check.sh" --check; then
		log_warn "Code formatting issues found"
		read -p "Auto-fix formatting issues? (Y/n): " fix_format
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

	read -p "Enter VM name [$USER-tailscale-tor]: " VM_NAME
	VM_NAME="${VM_NAME:-$USER-tailscale-tor}"

	read -p "Enter username for the VM [ubuntu]: " VM_USERNAME
	VM_USERNAME="${VM_USERNAME:-ubuntu}"

	while true; do
		read -s -p "Enter password for VM user ($VM_USERNAME): " VM_PASSWORD
		echo
		if [[ -z "$VM_PASSWORD" ]]; then
			log_warn "Password cannot be empty"
			continue
		fi
		if [[ ${#VM_PASSWORD} -lt 8 ]]; then
			log_warn "Password must be at least 8 characters long"
			continue
		fi
		read -s -p "Confirm password: " VM_PASSWORD_CONFIRM
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
		read -p "Enter Tailscale auth key: " TAILSCALE_AUTH_KEY
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
	read -p "Enter memory size in MB [2048]: " MEMORY_MB
	MEMORY_MB="${MEMORY_MB:-2048}"

	read -p "Enter number of CPUs [2]: " VCPU_COUNT
	VCPU_COUNT="${VCPU_COUNT:-2}"

	read -p "Enter disk size in GB [20]: " DISK_SIZE_GB
	DISK_SIZE_GB="${DISK_SIZE_GB:-20}"

	echo
	log_info "Configuration collected successfully"
	
	# Determine available storage pool
	STORAGE_POOL="default"
	if sudo virsh pool-info default >/dev/null 2>&1; then
		STORAGE_POOL="default"
		log_info "Using 'default' storage pool"
	elif sudo virsh pool-info images >/dev/null 2>&1; then
		STORAGE_POOL="images"
		log_info "Using 'images' storage pool"
	else
		log_error "No suitable storage pool found"
		exit 1
	fi
	
	export TF_VAR_vm_name="$VM_NAME"
	export TF_VAR_vm_username="$VM_USERNAME"
	export TF_VAR_vm_password="$VM_PASSWORD"
	export TF_VAR_tailscale_auth_key="$TAILSCALE_AUTH_KEY"
	export TF_VAR_memory_mb="$MEMORY_MB"
	export TF_VAR_vcpu_count="$VCPU_COUNT"
	export TF_VAR_disk_size_gb="$DISK_SIZE_GB"
	export TF_VAR_storage_pool="$STORAGE_POOL"
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

	# Check if default network exists
	if ! sudo virsh net-info default >/dev/null 2>&1; then
		log_info "Creating default network..."
		sudo virsh net-define /usr/share/libvirt/networks/default.xml
		sudo virsh net-autostart default
		sudo virsh net-start default
	fi

	# Check storage pools
	log_info "Checking storage pools..."
	
	# First, try to find an existing suitable pool
	if sudo virsh pool-info default >/dev/null 2>&1; then
		log_info "Default pool already exists"
		# Ensure it's started
		if ! sudo virsh pool-info default | grep -q "State:.*running"; then
			sudo virsh pool-start default >/dev/null 2>&1 || true
		fi
	else
		# Check if 'images' pool exists (common on many systems)
		if sudo virsh pool-info images >/dev/null 2>&1; then
			log_info "Using existing 'images' storage pool"
			# We'll use the images pool instead of creating default
		else
			# Create default pool only if neither exists
			log_info "Creating default storage pool..."
			
			# Ensure directory exists
			sudo mkdir -p /var/lib/libvirt/images
			
			# Create temporary XML for storage pool
			cat <<EOF > /tmp/default-pool.xml
<pool type='dir'>
  <name>default</name>
  <target>
    <path>/var/lib/libvirt/images</path>
  </target>
</pool>
EOF
			if sudo virsh pool-define /tmp/default-pool.xml >/dev/null 2>&1; then
				sudo virsh pool-autostart default
				sudo virsh pool-start default
				log_success "Default storage pool created"
			else
				log_warn "Could not create default pool, will use images pool if available"
			fi
			rm -f /tmp/default-pool.xml
		fi
	fi

	log_success "Libvirt setup verified"
}

check_provider_config() {
	log_info "Checking cloud provider configuration..."

	if [[ -z "${TF_VAR_ami_id:-}" && -z "${TF_VAR_project_id:-}" ]]; then
		log_warn "No cloud provider configuration detected"
		echo
		echo "Please set provider-specific environment variables:"
		echo
		echo "For AWS:"
		echo "  export TF_VAR_ami_id='ami-0c02fb55956c7d316'"
		echo "  export TF_VAR_region='us-west-2'"
		echo "  export TF_VAR_subnet_id='subnet-xxxxxxxxx'"
		echo "  export TF_VAR_vpc_id='vpc-xxxxxxxxx'"
		echo
		echo "For GCP:"
		echo "  export TF_VAR_project_id='your-gcp-project'"
		echo "  export TF_VAR_region='us-central1'"
		echo "  export TF_VAR_zone='us-central1-a'"
		echo
		exit 1
	fi
}

generate_ssh_key() {
	log_info "Generating RSA 4096 SSH keypair..."

	if [[ -f "$TERRAFORM_DIR/private_key.pem" ]]; then
		log_warn "SSH key already exists, skipping generation"
		return 0
	fi

	ssh-keygen -t rsa -b 4096 -f "$TERRAFORM_DIR/private_key.pem" -N "" -C "tailscale-exit-node-$(date +%Y%m%d)"
	chmod 600 "$TERRAFORM_DIR/private_key.pem"
	chmod 644 "$TERRAFORM_DIR/private_key.pem.pub"

	log_success "SSH keypair generated successfully"
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
		log_error "Terraform apply failed"
		exit 1
	fi

	log_success "Infrastructure provisioned successfully"
}

generate_ansible_inventory() {
	log_info "Generating Ansible inventory..."

	log_info "Script directory: $SCRIPT_DIR"
	log_info "Project root: $PROJECT_ROOT"
	log_info "Terraform directory: $TERRAFORM_DIR"
	log_info "Current working directory: $(pwd)"
	
	if [[ ! -d "$TERRAFORM_DIR" ]]; then
		log_error "Terraform directory not found: $TERRAFORM_DIR"
		log_error "Directory contents of project root:"
		ls -la "$PROJECT_ROOT" || echo "Cannot list project root"
		exit 1
	fi

	cd "$TERRAFORM_DIR"
	local vm_ip
	vm_ip=$(terraform output -raw vm_ip 2>/dev/null)

	if [[ -z "$vm_ip" ]]; then
		log_error "Could not retrieve VM IP from Terraform"
		exit 1
	fi

	# Generate inventory from template
	sed "s/VM_IP/$vm_ip/g; s/TAILSCALE_AUTH_KEY/$TAILSCALE_AUTH_KEY/g; s/VM_HOSTNAME/$VM_NAME/g; s/VM_USERNAME/$VM_USERNAME/g; s/VM_MEMORY/$MEMORY_MB/g; s/VM_VCPUS/$VCPU_COUNT/g" \
		"$ANSIBLE_DIR/inventory.ini.tpl" > "$ANSIBLE_DIR/inventory.ini"

	log_success "Ansible inventory generated for VM: $vm_ip"
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

	# Build optional extra-vars to control handlers

	if ! ansible-playbook -i inventory.ini playbook.yml -e disable_handlers=true; then
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
	run_terraform
	generate_ansible_inventory
	wait_for_ssh
	run_ansible
	display_results

	log_success "All deployment steps completed successfully"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
