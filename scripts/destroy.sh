#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly TERRAFORM_DIR="$PROJECT_ROOT/terraform"
readonly ANSIBLE_DIR="$PROJECT_ROOT/ansible"

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

confirm_destruction() {
	local vm_ip=""

	if [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
		vm_ip=$(cd "$TERRAFORM_DIR" && terraform output -raw vm_ip 2>/dev/null || echo "unknown")
	fi

	echo
	log_warn "You are about to destroy the KVM Tailscale Tor Exit Node!"
	echo
	echo "This will permanently delete:"
	echo "  - Virtual machine and all data"
	echo "  - SSH keys and certificates"
	echo "  - All configuration and logs"
	if [[ -n "$vm_ip" && "$vm_ip" != "unknown" ]]; then
		echo "  - VM at IP: $vm_ip"
	fi
	echo

	read -p "Are you sure you want to proceed? (type 'yes' to confirm): " confirmation

	if [[ "$confirmation" != "yes" ]]; then
		log_info "Destruction cancelled by user"
		exit 0
	fi

	echo
	read -p "This action is IRREVERSIBLE. Type 'DESTROY' to confirm: " final_confirmation

	if [[ "$final_confirmation" != "DESTROY" ]]; then
		log_info "Destruction cancelled by user"
		exit 0
	fi

	log_warn "Proceeding with infrastructure destruction..."
}

backup_important_data() {
	log_info "Creating backup of important configuration..."

	local backup_dir="/tmp/tailscale-tor-backup-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$backup_dir"

	if [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
		cp "$TERRAFORM_DIR/terraform.tfstate" "$backup_dir/terraform.tfstate.backup"
		log_info "Terraform state backed up to $backup_dir"
	fi

	if [[ -f "$ANSIBLE_DIR/inventory.ini" ]]; then
		cp "$ANSIBLE_DIR/inventory.ini" "$backup_dir/inventory.ini.backup"
	fi

	if [[ -f "$TERRAFORM_DIR/vm_key" ]]; then
		cp "$TERRAFORM_DIR/vm_key" "$backup_dir/vm_key.backup"
		chmod 600 "$backup_dir/vm_key.backup"
	fi

	echo "$backup_dir" >/tmp/last-tailscale-tor-backup
	log_success "Backup created at: $backup_dir"
}

fetch_final_logs() {
	log_info "Fetching final logs before destruction..."

	if [[ -f "$TERRAFORM_DIR/vm_key" ]] && [[ -f "$ANSIBLE_DIR/inventory.ini" ]]; then
		local vm_ip
		vm_ip=$(grep ansible_host "$ANSIBLE_DIR/inventory.ini" | cut -d= -f2 2>/dev/null || echo "")
		local vm_username="ubuntu"

		if [[ -n "$public_ip" && -n "$vm_username" ]]; then
			local log_backup="/tmp/final-logs-$(date +%Y%m%d-%H%M%S).txt"

			log_info "Collecting final system state..."
			ssh -i "$TERRAFORM_DIR/private_key.pem" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$vm_username@$public_ip" "
                echo '=== FINAL SYSTEM STATE ===' > /tmp/final-logs.txt
                echo 'Date: $(date)' >> /tmp/final-logs.txt
                echo >> /tmp/final-logs.txt
                
                echo '=== TAILSCALE STATUS ===' >> /tmp/final-logs.txt
                sudo tailscale status >> /tmp/final-logs.txt 2>&1 || echo 'Tailscale not running' >> /tmp/final-logs.txt
                echo >> /tmp/final-logs.txt
                
                echo '=== TOR CONTAINER LOGS ===' >> /tmp/final-logs.txt
                sudo docker logs tor-proxy --tail 20 >> /tmp/final-logs.txt 2>&1 || echo 'Tor container not running' >> /tmp/final-logs.txt
                echo >> /tmp/final-logs.txt
                
                echo '=== IPTABLES RULES ===' >> /tmp/final-logs.txt
                sudo iptables -t nat -L -n -v >> /tmp/final-logs.txt 2>&1 || echo 'Cannot read iptables' >> /tmp/final-logs.txt
                echo >> /tmp/final-logs.txt
                
                echo '=== SYSTEM STATUS ===' >> /tmp/final-logs.txt
                sudo systemctl status tailscaled docker tor-monitor node_exporter >> /tmp/final-logs.txt 2>&1 || echo 'Cannot read service status' >> /tmp/final-logs.txt
                
                cat /tmp/final-logs.txt
            " >"$log_backup" 2>/dev/null || log_warn "Could not fetch final logs from remote system"

			if [[ -s "$log_backup" ]]; then
				log_success "Final logs saved to: $log_backup"
			fi
		fi
	else
		log_warn "No SSH access available, skipping log collection"
	fi
}

destroy_terraform_infrastructure() {
	log_info "Destroying Terraform infrastructure..."

	cd "$TERRAFORM_DIR"

	if [[ ! -f "terraform.tfstate" ]] && [[ ! -d ".terraform" ]]; then
		log_warn "No Terraform state found, nothing to destroy"
		return 0
	fi

	if [[ -d ".terraform" ]]; then
		log_info "Initializing Terraform..."
		terraform init -input=false
	fi

	# Set dummy values for required variables during destroy
	export TF_VAR_tailscale_auth_key="dummy_key_for_destroy"
	export TF_VAR_vm_name="dummy-vm"
	export TF_VAR_vm_username="ubuntu"
	export TF_VAR_vm_password="dummy_password"

	log_info "Planning destruction..."
	if terraform plan -destroy -out=destroy.tfplan -input=false; then
		log_info "Applying destruction plan..."
		if terraform apply -auto-approve destroy.tfplan; then
			log_success "Infrastructure destroyed successfully"
			rm -f destroy.tfplan
		else
			log_error "Failed to destroy infrastructure"
			return 1
		fi
	else
		log_error "Failed to plan destruction"
		return 1
	fi
}

cleanup_libvirt_resources() {
	log_info "Cleaning up remaining libvirt resources..."

	# Get VM name from terraform state if available
	local vm_name=""
	if [[ -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
		vm_name=$(cd "$TERRAFORM_DIR" && terraform output -raw vm_name 2>/dev/null || echo "")
	fi

	# If we can't get VM name from terraform, try to find VMs with our pattern
	if [[ -z "$vm_name" ]]; then
		log_info "Searching for VMs with 'tailscale' or 'tor' in name..."
		local vm_list
		vm_list=$(sudo virsh list --all --name | grep -E "(tailscale|tor)" || echo "")
		
		if [[ -n "$vm_list" ]]; then
			echo "Found the following VMs:"
			echo "$vm_list"
			echo
			read -p "Do you want to delete these VMs? (y/N): " confirm_vm_delete
			if [[ "$confirm_vm_delete" == "y" || "$confirm_vm_delete" == "Y" ]]; then
				echo "$vm_list" | while read -r vm; do
					if [[ -n "$vm" ]]; then
						log_info "Destroying VM: $vm"
						sudo virsh destroy "$vm" 2>/dev/null || true
						sudo virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
					fi
				done
			fi
		fi
	else
		# We have VM name from terraform
		log_info "Cleaning up VM: $vm_name"
		sudo virsh destroy "$vm_name" 2>/dev/null || true
		sudo virsh undefine "$vm_name" --remove-all-storage 2>/dev/null || true
	fi

	# Clean up networks
	log_info "Cleaning up custom networks..."
	local network_list
	network_list=$(sudo virsh net-list --all --name | grep -E "(tailscale|tor)" || echo "")
	
	if [[ -n "$network_list" ]]; then
		echo "Found the following networks:"
		echo "$network_list"
		echo
		read -p "Do you want to delete these networks? (y/N): " confirm_net_delete
		if [[ "$confirm_net_delete" == "y" || "$confirm_net_delete" == "Y" ]]; then
			echo "$network_list" | while read -r net; do
				if [[ -n "$net" ]]; then
					log_info "Destroying network: $net"
					sudo virsh net-destroy "$net" 2>/dev/null || true
					sudo virsh net-undefine "$net" 2>/dev/null || true
				fi
			done
		fi
	fi

	# Clean up volumes
	log_info "Cleaning up volumes..."
	local volume_list
	volume_list=$(sudo virsh vol-list default 2>/dev/null | grep -E "(tailscale|tor|ubuntu)" | awk '{print $1}' || echo "")
	
	if [[ -n "$volume_list" ]]; then
		echo "Found the following volumes:"
		echo "$volume_list"
		echo
		read -p "Do you want to delete these volumes? (y/N): " confirm_vol_delete
		if [[ "$confirm_vol_delete" == "y" || "$confirm_vol_delete" == "Y" ]]; then
			echo "$volume_list" | while read -r vol; do
				if [[ -n "$vol" ]]; then
					log_info "Deleting volume: $vol"
					sudo virsh vol-delete "$vol" default 2>/dev/null || true
				fi
			done
		fi
	fi

	# Also check images pool if it exists
	if sudo virsh pool-info images >/dev/null 2>&1; then
		volume_list=$(sudo virsh vol-list images 2>/dev/null | grep -E "(tailscale|tor|ubuntu)" | awk '{print $1}' || echo "")
		if [[ -n "$volume_list" ]]; then
			echo "Found volumes in images pool:"
			echo "$volume_list"
			echo
			read -p "Do you want to delete these volumes from images pool? (y/N): " confirm_img_vol_delete
			if [[ "$confirm_img_vol_delete" == "y" || "$confirm_img_vol_delete" == "Y" ]]; then
				echo "$volume_list" | while read -r vol; do
					if [[ -n "$vol" ]]; then
						log_info "Deleting volume from images pool: $vol"
						sudo virsh vol-delete "$vol" images 2>/dev/null || true
					fi
				done
			fi
		fi
	fi

	log_success "Libvirt cleanup completed"
}

cleanup_local_files() {
	log_info "Cleaning up local files..."

	local files_to_remove=(
		"$TERRAFORM_DIR/.terraform"
		"$TERRAFORM_DIR/.terraform.lock.hcl"
		"$TERRAFORM_DIR/terraform.tfstate"
		"$TERRAFORM_DIR/terraform.tfstate.backup"
		"$TERRAFORM_DIR/vm_key"
		"$TERRAFORM_DIR/vm_key.pub"
		"$TERRAFORM_DIR/destroy.tfplan"
		"$ANSIBLE_DIR/inventory.ini"
	)

	for file in "${files_to_remove[@]}"; do
		if [[ -e "$file" ]]; then
			rm -rf "$file"
			log_info "Removed: $file"
		fi
	done

	find /tmp -name "tailscale-tor-verification-*.txt" -delete 2>/dev/null || true
	find /tmp -name "leak-test-report-*.txt" -delete 2>/dev/null || true

	log_success "Local cleanup completed"
}

verify_destruction() {
	log_info "Verifying destruction..."

	cd "$TERRAFORM_DIR"

	local remaining_resources
	remaining_resources=$(terraform show 2>/dev/null | grep -c "resource" || echo "0")

	if [[ "$remaining_resources" -eq 0 ]]; then
		log_success "No Terraform resources remain"
	else
		log_warn "$remaining_resources Terraform resources may still exist"
	fi

	local remaining_files=0
	local sensitive_files=(
		"$TERRAFORM_DIR/terraform.tfstate"
		"$TERRAFORM_DIR/private_key.pem"
		"$ANSIBLE_DIR/inventory.ini"
	)

	for file in "${sensitive_files[@]}"; do
		if [[ -f "$file" ]]; then
			((remaining_files++))
			log_warn "Sensitive file still exists: $file"
		fi
	done

	if [[ $remaining_files -eq 0 ]]; then
		log_success "All sensitive files removed"
	else
		log_warn "$remaining_files sensitive files remain"
	fi
}

show_destruction_summary() {
	log_success "Destruction completed successfully!"
	echo
	echo "=== DESTRUCTION SUMMARY ==="
	echo "Date: $(date)"
	echo "Infrastructure: Destroyed"
	echo "Local files: Cleaned"
	echo "Backups: Available in /tmp/tailscale-tor-backup-*"
	if [[ -f "/tmp/last-tailscale-tor-backup" ]]; then
		echo "Latest backup: $(cat /tmp/last-tailscale-tor-backup)"
	fi
	echo

	echo "=== SECURITY NOTES ==="
	echo "- All VM data has been permanently deleted"
	echo "- SSH keys have been removed from the system"
	echo "- Tailscale device should be removed from admin panel"
	echo "- Cloud provider resources have been destroyed"
	echo

	echo "=== RECOVERY ==="
	echo "To redeploy:"
	echo "1. Run: make deploy"
	echo "2. Configure new Tailscale auth key"
	echo "3. Authorize new exit node in Tailscale admin"
	echo

	log_info "Destruction process completed successfully"
}

handle_error() {
	log_error "An error occurred during destruction"
	echo
	echo "=== ERROR RECOVERY ==="
	echo "1. Check libvirt resources: sudo virsh list --all"
	echo "2. Manually delete VMs: sudo virsh destroy <vm-name> && sudo virsh undefine <vm-name> --remove-all-storage"
	echo "3. Check networks: sudo virsh net-list --all"
	echo "4. Check volumes: sudo virsh vol-list default"
	echo "5. Run 'make clean' to remove local files"
	echo "6. Check backup files in /tmp/tailscale-tor-backup-*"
	echo
	exit 1
}

main() {
	log_info "Starting Tailscale Tor Exit Node destruction process..."

	trap handle_error ERR

	confirm_destruction
	backup_important_data
	fetch_final_logs
	destroy_terraform_infrastructure
	cleanup_libvirt_resources
	cleanup_local_files
	verify_destruction
	show_destruction_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
