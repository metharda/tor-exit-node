.PHONY: help check format deploy destroy verify test clean install-deps status logs setup-python
.DEFAULT_GOAL := help

TERRAFORM_DIR := terraform
ANSIBLE_DIR := ansible
SCRIPTS_DIR := scripts

help:
	@echo "Tailscale Tor Exit Node - Available targets:"
	@echo "  check       - Run all checks (dependencies, format, lint)"
	@echo "  format      - Format all code (terraform, ansible, scripts)"
	@echo "  deploy      - Deploy complete infrastructure (with pre-checks)"
	@echo "  verify      - Verify deployment and test for leaks"
	@echo "  test        - Run comprehensive leak tests"
	@echo "  destroy     - Destroy infrastructure safely (with libvirt cleanup)"
	@echo "  uninstall   - Complete uninstall (same as destroy)"
	@echo "  clean       - Clean temporary files"
	@echo "  install-deps- Install missing dependencies"
	@echo "  setup-python- Setup Python virtual environment"
	@echo "  status      - Show infrastructure status"
	@echo "  logs        - Fetch remote logs"

check: check-deps check-format lint
	@echo "All checks passed"

check-deps:
	@echo "Checking dependencies..."
	@$(SCRIPTS_DIR)/check-dependencies.sh

check-format:
	@echo "Checking code formatting..."
	@$(SCRIPTS_DIR)/format-check.sh --check

format:
	@echo "Formatting code..."
	@$(SCRIPTS_DIR)/format-check.sh --fix

format-fix:
	@echo "Automatically fixing format issues..."
	@$(SCRIPTS_DIR)/auto-fix-format.sh
	@echo "Running format checks after fixes..."
	@$(SCRIPTS_DIR)/format-check.sh --check

lint:
	@echo "Running linters..."
	@cd $(ANSIBLE_DIR) && ansible-lint playbook.yml
	@cd $(TERRAFORM_DIR) && terraform validate

deploy:
	@echo "Starting deployment with pre-checks..."
	@$(SCRIPTS_DIR)/deploy.sh

verify:
	@echo "Verifying deployment..."
	@$(SCRIPTS_DIR)/verify-deployment.sh

test:
	@echo "Running leak tests..."
	@$(SCRIPTS_DIR)/leak-test.sh

destroy: clean
	@echo "Destroying infrastructure safely..."
	@$(SCRIPTS_DIR)/destroy.sh

uninstall: destroy
	@echo "Complete uninstall completed (same as destroy)"

clean:
	@echo "Cleaning temporary files..."
	@rm -rf $(TERRAFORM_DIR)/.terraform
	@rm -f $(TERRAFORM_DIR)/.terraform.lock.hcl
	@rm -f $(TERRAFORM_DIR)/terraform.tfstate*
	@rm -f $(TERRAFORM_DIR)/vm_key*
	@rm -f $(TERRAFORM_DIR)/tfplan
	@rm -f $(ANSIBLE_DIR)/inventory.ini
	@rm -f /tmp/tailscale-tor-verification-*.txt
	@rm -f /tmp/leak-test-report-*.txt
	@echo "Cleanup complete"

install-deps:
	@echo "Installing dependencies..."
	@$(SCRIPTS_DIR)/check-dependencies.sh --install

setup-python:
	@echo "Setting up Python environment..."
	@if [ ! -f ~/.tailscale-tor-venv-path ]; then \
		python3 -m venv ~/.local/tailscale-tor-venv; \
		echo "$$HOME/.local/tailscale-tor-venv/bin/activate" > ~/.tailscale-tor-venv-path; \
		echo "Virtual environment created"; \
	fi
	@. ~/.local/tailscale-tor-venv/bin/activate && pip install --upgrade pip ansible-lint yamllint
	@echo "Python environment ready"

status:
	@echo "Infrastructure status:"
	@cd $(TERRAFORM_DIR) && terraform show 2>/dev/null | grep -E "(public_ip|instance_id|state)" || echo "No infrastructure found"

logs:
	@echo "Fetching remote logs..."
	@if [ -f $(TERRAFORM_DIR)/private_key.pem ] && [ -f $(ANSIBLE_DIR)/inventory.ini ]; then \
		ssh -i $(TERRAFORM_DIR)/private_key.pem -o StrictHostKeyChecking=no $$(grep ansible_host $(ANSIBLE_DIR)/inventory.ini | cut -d= -f2) \
			'sudo docker logs tor-proxy --tail 50 2>/dev/null || echo "Tor container not running"'; \
	else \
		echo "No SSH key or inventory found. Run 'make deploy' first."; \
	fi