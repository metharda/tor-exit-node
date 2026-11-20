.PHONY: help check-deps deploy configure verify status logs ssh destroy lint clean
.DEFAULT_GOAL := help

TF := terraform -chdir=terraform
# With empty state `terraform output` warns but exits 0, so match an address.
HAS_VM := $(TF) output -raw vm_ip 2>/dev/null | grep -Eq '^[0-9]+(\.[0-9]+){3}$$'
SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
# Expanded when used, so targets that don't need a VM don't touch Terraform.
VM = $(shell $(TF) output -raw vm_username 2>/dev/null)@$(shell $(TF) output -raw vm_ip 2>/dev/null)
SSH = ssh -i terraform/vm_key $(SSH_OPTS)

help:
	@echo "Tailscale Tor exit node"
	@echo
	@echo "  make check-deps   check host prerequisites (Terraform, Ansible, libvirt, KVM)"
	@echo "  make deploy       create and configure the VM (prompts; see README for env vars)"
	@echo "  make configure    re-run the Ansible configuration on the existing VM"
	@echo "  make verify       run the health and leak check on the VM"
	@echo "  make status       show VM, Tor, transparent proxy and Tailscale state"
	@echo "  make logs         show recent Tor and watchdog logs"
	@echo "  make ssh          open a shell on the VM"
	@echo "  make destroy      delete the VM and all resources Terraform created"
	@echo "  make lint         static checks (shellcheck, terraform validate, ansible-lint)"
	@echo "  make clean        remove local Terraform caches (only when nothing is deployed)"

check-deps:
	@scripts/check-dependencies.sh

deploy:
	@scripts/deploy.sh

configure: require-vm
	@cd ansible && ansible-playbook playbook.yml

verify: require-vm
	@$(SSH) -t $(VM) 'sudo /usr/local/sbin/tor-exit-check'

status: require-vm
	@$(TF) output
	@$(SSH) $(VM) 'echo; sudo docker ps --filter name=tor-proxy --format "tor-proxy: {{.Status}}"; \
		sudo /usr/local/sbin/transparent-proxy status; echo; sudo tailscale status'

logs: require-vm
	@$(SSH) $(VM) 'sudo docker logs --tail 40 tor-proxy; echo; sudo journalctl -u tor-watchdog -u transparent-proxy -n 20 --no-pager'

ssh: require-vm
	@$(SSH) $(VM)

destroy:
	@scripts/destroy.sh

lint:
	shellcheck -x scripts/*.sh ansible/roles/*/files/*.sh
	$(TF) init -backend=false -input=false >/dev/null && $(TF) validate
	$(TF) fmt -check -recursive
	cd ansible && ansible-lint playbook.yml

clean:
	@if $(HAS_VM); then \
		echo "A VM is still deployed; run 'make destroy' first." >&2; exit 1; fi
	rm -rf terraform/.terraform terraform/tfplan ansible/inventory.ini terraform/vm_key

.PHONY: require-vm
require-vm:
	@$(HAS_VM) || { echo "No VM deployed. Run 'make deploy' first." >&2; exit 1; }
