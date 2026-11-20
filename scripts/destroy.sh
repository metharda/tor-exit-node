#!/bin/bash
# Destroy the exit node VM and everything Terraform created for it (VM, disks,
# storage pool, network), then remove the local key and inventory. Also works
# for a partial deployment, e.g. when the VM never came up.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

if ! terraform -chdir="$TERRAFORM_DIR" state list 2>/dev/null | grep -q .; then
	die "nothing to destroy: Terraform state is empty. Leftover resources can be listed with 'sudo virsh list --all' and 'sudo virsh net-list --all'."
fi

vm_name=$(terraform -chdir="$TERRAFORM_DIR" output -raw vm_name 2>/dev/null | grep -E '^[a-z0-9-]+$' || echo destroy)

step "Destroying the exit node deployment"
info "This deletes the VM, its disk, its storage pool and its network."
info "Remember to remove the machine from https://login.tailscale.com/admin/machines"
if [[ "${CONFIRM:-}" != "$vm_name" ]]; then
	read -rp "    Type '$vm_name' to confirm: " CONFIRM || true
	[[ "$CONFIRM" == "$vm_name" ]] || die "confirmation did not match, nothing was destroyed"
fi

# The password is not needed to destroy, but the variable has no default.
TF_VAR_vm_password="${TF_VAR_vm_password:-unused-for-destroy}" \
	terraform -chdir="$TERRAFORM_DIR" destroy -input=false -auto-approve

rm -f "$ANSIBLE_DIR/inventory.ini" "$TERRAFORM_DIR/vm_key"
ok "deployment destroyed"
