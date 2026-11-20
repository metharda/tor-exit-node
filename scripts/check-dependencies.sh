#!/bin/bash
# Check that this host can deploy the exit node: tools on PATH, KVM, and access
# to the system libvirt daemon.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

missing=0
need() {
	local cmd="$1" hint="$2"
	if command -v "$cmd" >/dev/null 2>&1; then
		ok "$cmd"
	else
		warn "$cmd not found: $hint"
		missing=$((missing + 1))
	fi
}

step "Checking host prerequisites"
need terraform "https://developer.hashicorp.com/terraform/install"
need ansible-playbook "pipx install --include-deps ansible (or: apt install ansible)"
need virsh "apt install libvirt-daemon-system libvirt-clients qemu-kvm"
need ssh "apt install openssh-client"
need xsltproc "apt install xsltproc (used by the libvirt provider to set the disk type)"

if [[ -e /dev/kvm ]]; then
	ok "KVM (/dev/kvm)"
else
	warn "/dev/kvm missing: enable virtualization in the BIOS or nested virtualization"
	missing=$((missing + 1))
fi

if command -v virsh >/dev/null 2>&1; then
	if virsh -c qemu:///system list >/dev/null 2>&1; then
		ok "libvirt (qemu:///system)"
	else
		warn "cannot reach qemu:///system: start libvirtd and add yourself to the libvirt group"
		missing=$((missing + 1))
	fi
fi

if command -v ansible-galaxy >/dev/null 2>&1; then
	for collection in community.general ansible.posix; do
		if ansible-galaxy collection list "$collection" 2>/dev/null | grep -q "^$collection "; then
			ok "Ansible collection $collection"
		else
			warn "Ansible collection $collection missing: ansible-galaxy collection install $collection"
			missing=$((missing + 1))
		fi
	done
fi

((missing == 0)) || die "$missing prerequisite(s) missing"
