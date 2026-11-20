#!/bin/bash
# Provision the exit node VM with Terraform, then configure it with Ansible.
#
# Every prompt can be answered through the environment for unattended runs:
#   VM_NAME VM_USERNAME VM_PASSWORD VM_MEMORY_MB VM_VCPUS VM_DISK_GB TS_AUTHKEY
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

# ask VAR "Prompt" default — keeps an existing value of $VAR.
ask() {
	local var="$1" prompt="$2" default="$3" reply
	if [[ -z "${!var:-}" ]]; then
		read -rp "    $prompt [$default]: " reply
		printf -v "$var" '%s' "${reply:-$default}"
	fi
}

ask_password() {
	local confirm
	while [[ ${#VM_PASSWORD} -lt 8 ]]; do
		read -rsp "    VM console password (min. 8 characters): " VM_PASSWORD
		echo
		if [[ ${#VM_PASSWORD} -lt 8 ]]; then
			warn "too short"
			continue
		fi
		read -rsp "    Confirm password: " confirm
		echo
		if [[ "$VM_PASSWORD" != "$confirm" ]]; then
			warn "passwords do not match"
			VM_PASSWORD=""
		fi
	done
}

ask_authkey() {
	until [[ "$TS_AUTHKEY" =~ ^tskey-auth-[A-Za-z0-9_-]{10,}$ ]]; do
		[[ -n "$TS_AUTHKEY" ]] && warn "that does not look like an auth key (tskey-auth-...)"
		info "Create one at https://login.tailscale.com/admin/settings/keys"
		info "(reusable is handy for retries; not ephemeral; optional tag such as tag:exit-node)"
		read -rsp "    Tailscale auth key (input hidden): " TS_AUTHKEY
		echo
	done
}

main() {
	"$PROJECT_ROOT/scripts/check-dependencies.sh"

	if deployed; then
		die "a VM is already deployed ($(terraform -chdir="$TERRAFORM_DIR" output -raw vm_name)). Run 'make configure' to re-apply the configuration or 'make destroy' first."
	fi

	step "Configuration"
	ask VM_NAME "VM name" "tailscale-tor-exit"
	ask VM_USERNAME "VM user" "ubuntu"
	ask VM_MEMORY_MB "Memory (MB)" "2048"
	ask VM_VCPUS "vCPUs" "2"
	ask VM_DISK_GB "Disk (GB)" "20"
	VM_PASSWORD="${VM_PASSWORD:-}"
	ask_password
	TS_AUTHKEY="${TS_AUTHKEY:-}"
	ask_authkey

	export TF_VAR_vm_name="$VM_NAME" TF_VAR_vm_username="$VM_USERNAME" TF_VAR_vm_password="$VM_PASSWORD"
	export TF_VAR_memory_mb="$VM_MEMORY_MB" TF_VAR_vcpu_count="$VM_VCPUS" TF_VAR_disk_size_gb="$VM_DISK_GB"
	export TS_AUTHKEY

	step "Provisioning the VM (Terraform)"
	terraform -chdir="$TERRAFORM_DIR" init -input=false -upgrade >/dev/null
	terraform -chdir="$TERRAFORM_DIR" apply -input=false -auto-approve
	ok "VM $VM_NAME is running at $(terraform -chdir="$TERRAFORM_DIR" output -raw vm_ip)"

	step "Configuring the VM (Ansible, about 10 minutes)"
	if ! (cd "$ANSIBLE_DIR" && ansible-playbook playbook.yml); then
		warn "Configuration failed. The VM was left running so you can inspect it:"
		info "make ssh          open a shell on the VM"
		info "make configure    re-run the configuration (TS_AUTHKEY is only needed until the node has joined)"
		info "make destroy      remove the VM"
		exit 1
	fi

	step "Done"
	ok "Exit node $VM_NAME is configured"
	info "1. Approve it as an exit node: https://login.tailscale.com/admin/machines"
	info "2. On a client:  tailscale set --exit-node=$VM_NAME"
	info "3. Confirm:      curl https://check.torproject.org/api/ip"
	info "Check health any time with 'make verify'."
}

main "$@"
