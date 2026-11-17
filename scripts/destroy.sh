#!/bin/bash

# Destroys only what this deployment created: the resources in the Terraform
# state (VM, disks, cloud-init ISO, base volume, project network) plus the
# local files deploy.sh generated. Without a state it falls back to the exact
# resource names derived from the deployed vm_name and storage_pool (saved in
# terraform/deploy.auto.tfvars.json). It never matches libvirt objects by pattern.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly SCRIPT_DIR PROJECT_ROOT
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

tf() {
	(cd "$TERRAFORM_DIR" && terraform "$@")
}

readonly TFVARS="$TERRAFORM_DIR/deploy.auto.tfvars.json"

tfvar() {
	python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$TFVARS" "$1"
}

# Deletes a leftover deployment by exact names only (used when there is no state,
# for example after an interrupted deploy).
destroy_by_exact_names() {
	local vm_name pool
	vm_name=$(tfvar vm_name)
	pool=$(tfvar storage_pool)
	if [[ ! "$vm_name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ || -z "$pool" ]]; then
		log_error "$TFVARS has no valid vm_name/storage_pool; deleting nothing"
		exit 1
	fi

	local found=() vol
	sudo virsh dominfo "$vm_name" >/dev/null 2>&1 && found+=("domain $vm_name")
	sudo virsh net-info "$vm_name-network" >/dev/null 2>&1 && found+=("network $vm_name-network")
	for vol in "$vm_name-disk.qcow2" "$vm_name-cloud-init.iso" "$vm_name-ubuntu-22.04-base.qcow2"; do
		sudo virsh vol-info "$vol" --pool "$pool" >/dev/null 2>&1 && found+=("volume $pool/$vol")
	done

	if [[ ${#found[@]} -eq 0 ]]; then
		log_info "No Terraform state and no resources named after '$vm_name'; nothing to destroy"
		cleanup_local_files
		exit 0
	fi

	log_warn "No Terraform state, but these resources of deployment '$vm_name' exist:"
	printf '  - %s\n' "${found[@]}"
	local confirmation=""
	read -r -p "Type 'yes' to delete exactly these: " confirmation || true
	if [[ "$confirmation" != "yes" ]]; then
		log_info "Destruction cancelled; nothing was deleted"
		exit 1
	fi

	if sudo virsh dominfo "$vm_name" >/dev/null 2>&1; then
		sudo virsh destroy "$vm_name" >/dev/null 2>&1 || true
		sudo virsh undefine "$vm_name"
	fi
	if sudo virsh net-info "$vm_name-network" >/dev/null 2>&1; then
		sudo virsh net-destroy "$vm_name-network" >/dev/null 2>&1 || true
		sudo virsh net-undefine "$vm_name-network"
	fi
	for vol in "$vm_name-disk.qcow2" "$vm_name-cloud-init.iso" "$vm_name-ubuntu-22.04-base.qcow2"; do
		if sudo virsh vol-info "$vol" --pool "$pool" >/dev/null 2>&1; then
			sudo virsh vol-delete "$vol" --pool "$pool"
		fi
	done
	log_warn "Remove the Tailscale device at https://login.tailscale.com/admin/machines if it joined"
	cleanup_local_files
	log_success "Destruction completed"
	exit 0
}

check_state() {
	if [[ -s "$TERRAFORM_DIR/terraform.tfstate" ]]; then
		if [[ ! -d "$TERRAFORM_DIR/.terraform" ]]; then
			tf init -input=false >/dev/null
		fi
		RESOURCES=$(tf state list 2>/dev/null || true)
	else
		RESOURCES=""
	fi

	if [[ -z "$RESOURCES" ]]; then
		if [[ -f "$TFVARS" ]]; then
			destroy_by_exact_names
		fi
		log_info "No Terraform state found; nothing to destroy"
		exit 0
	fi

	VM_NAME=$(tf output -raw vm_name 2>/dev/null || true)
	VM_IP=$(tf output -raw vm_ip 2>/dev/null || true)
}

confirm_destruction() {
	echo
	log_warn "You are about to destroy the Tailscale Tor exit node '${VM_NAME:-unknown}' (${VM_IP:-no IP})."
	echo "These Terraform-managed resources will be deleted:"
	local resource
	while read -r resource; do
		echo "  - $resource"
	done <<<"$RESOURCES"
	echo "Local files: terraform/vm_key, terraform/vm_key.pub, ansible/inventory.ini, Terraform state"
	echo

	local confirmation=""
	read -r -p "Type 'yes' to destroy: " confirmation || true
	if [[ "$confirmation" != "yes" ]]; then
		log_info "Destruction cancelled; nothing was deleted"
		exit 1
	fi
}

logout_tailscale() {
	local vm_username
	vm_username=$(sed -n 's/.*ansible_user=\([^ ]*\).*/\1/p' "$ANSIBLE_DIR/inventory.ini" 2>/dev/null || true)

	if [[ -n "$VM_IP" && -n "$vm_username" && -f "$TERRAFORM_DIR/vm_key" ]] &&
		ssh -i "$TERRAFORM_DIR/vm_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			-o ConnectTimeout=10 -o BatchMode=yes "$vm_username@$VM_IP" 'sudo tailscale logout' >/dev/null 2>&1; then
		log_success "Tailscale device logged out"
	else
		log_warn "Could not log out of Tailscale; remove the device at https://login.tailscale.com/admin/machines"
	fi
}

destroy_infrastructure() {
	log_info "Destroying Terraform-managed resources..."
	# The VM password only feeds the cloud-init disk; it does not select resources,
	# and destroy works from the state, so a placeholder is enough here. All other
	# variables come from deploy.auto.tfvars.json, written by deploy.sh.
	if ! tf destroy -auto-approve -input=false -var "vm_password=not-used-on-destroy"; then
		log_error "terraform destroy failed; the state and local files were kept so you can retry"
		exit 1
	fi
	log_success "Terraform-managed resources destroyed"
}

cleanup_local_files() {
	rm -f "$TERRAFORM_DIR/vm_key" "$TERRAFORM_DIR/vm_key.pub" \
		"$TERRAFORM_DIR/terraform.tfstate" "$TERRAFORM_DIR/terraform.tfstate.backup" \
		"$TERRAFORM_DIR/deploy.auto.tfvars.json" "$TERRAFORM_DIR/tfplan" \
		"$ANSIBLE_DIR/inventory.ini"
	log_success "Local deployment files removed"
}

main() {
	check_state
	confirm_destruction
	logout_tailscale
	destroy_infrastructure
	cleanup_local_files
	log_success "Destruction completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
