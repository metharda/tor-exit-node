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

CHECK_MODE=true
FIX_MODE=false

if [[ "${1:-}" == "--fix" ]]; then
	CHECK_MODE=false
	FIX_MODE=true
elif [[ "${1:-}" == "--check" ]]; then
	CHECK_MODE=true
	FIX_MODE=false
fi

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

format_terraform() {
	log_info "Checking Terraform formatting..."

	if ! command -v terraform >/dev/null 2>&1; then
		log_warn "Terraform not found, skipping format check"
		return 0
	fi

	cd "$TERRAFORM_DIR"

	if [[ "$FIX_MODE" == "true" ]]; then
		log_info "Formatting Terraform files..."
		terraform fmt -recursive
		log_success "Terraform files formatted"
	else
		if terraform fmt -check -recursive; then
			log_success "Terraform files are properly formatted"
		else
			log_error "Terraform files need formatting"
			return 1
		fi
	fi
}

lint_ansible() {
	log_info "Checking Ansible syntax and linting..."

	if ! command -v ansible-playbook >/dev/null 2>&1; then
		log_warn "Ansible not found, skipping syntax check"
		return 0
	fi

	cd "$ANSIBLE_DIR"

	log_info "Checking Ansible playbook syntax..."
	if ansible-playbook --syntax-check playbook.yml; then
		log_success "Ansible playbook syntax is valid"
	else
		log_error "Ansible playbook syntax errors found"
		return 1
	fi

	local venv_path=""
	if [[ -f "$HOME/.tailscale-tor-venv-path" ]]; then
		venv_path=$(cat "$HOME/.tailscale-tor-venv-path")
		if [[ -f "$venv_path" ]]; then
			source "$venv_path"
		fi
	fi

	if command -v ansible-lint >/dev/null 2>&1; then
		log_info "Running ansible-lint..."
		if ansible-lint playbook.yml; then
			log_success "Ansible lint checks passed"
		else
			log_warn "Ansible lint warnings found (non-blocking)"
		fi
	else
		log_warn "ansible-lint not found, skipping lint checks"
		log_info "Run 'make install-deps' to install ansible-lint"
	fi
}

format_yaml() {
	log_info "Checking YAML formatting..."

	local venv_path=""
	if [[ -f "$HOME/.tailscale-tor-venv-path" ]]; then
		venv_path=$(cat "$HOME/.tailscale-tor-venv-path")
		if [[ -f "$venv_path" ]]; then
			source "$venv_path"
		fi
	fi

	if ! command -v yamllint >/dev/null 2>&1; then
		log_warn "yamllint not found, skipping YAML checks"
		log_info "Run 'make install-deps' to install yamllint"
		return 0
	fi

	local yaml_files
	yaml_files=$(find "$PROJECT_ROOT" -name "*.yml" -o -name "*.yaml" | grep -v ".git")

	if [[ -z "$yaml_files" ]]; then
		log_info "No YAML files found"
		return 0
	fi

	local yamllint_config
	yamllint_config=$(
		cat <<'EOF'
extends: default
rules:
  line-length:
    max: 120
    level: warning
  comments:
    min-spaces-from-content: 1
  comments-indentation: disable
  truthy:
    allowed-values: ['true', 'false', 'yes', 'no']
EOF
	)

	echo "$yamllint_config" >/tmp/yamllint-config.yml

	local errors=0
	while IFS= read -r file; do
		if yamllint -c /tmp/yamllint-config.yml "$file"; then
			log_success "YAML file $file is valid"
		else
			log_error "YAML file $file has issues"
			((errors++))
		fi
	done <<<"$yaml_files"

	rm -f /tmp/yamllint-config.yml

	if [[ $errors -gt 0 ]]; then
		return 1
	fi
}

check_shell_scripts() {
	log_info "Checking shell script formatting..."

	if ! command -v shellcheck >/dev/null 2>&1; then
		log_warn "shellcheck not found, skipping shell script checks"
		return 0
	fi

	local shell_scripts
	shell_scripts=$(find "$PROJECT_ROOT" -name "*.sh" | grep -v ".git")

	if [[ -z "$shell_scripts" ]]; then
		log_info "No shell scripts found"
		return 0
	fi

	local errors=0
	while IFS= read -r script; do
		log_info "Checking $script..."
		if shellcheck "$script"; then
			log_success "Shell script $script passed checks"
		else
			log_error "Shell script $script has issues"
			((errors++))
		fi
	done <<<"$shell_scripts"

	if [[ $errors -gt 0 ]]; then
		return 1
	fi
}

check_file_permissions() {
	log_info "Checking file permissions..."

	local script_files
	script_files=$(find "$PROJECT_ROOT" -name "*.sh" -type f)

	local errors=0
	while IFS= read -r script; do
		if [[ -x "$script" ]]; then
			log_success "$script is executable"
		else
			log_warn "$script is not executable"
			if [[ "$FIX_MODE" == "true" ]]; then
				chmod +x "$script"
				log_info "Made $script executable"
			else
				((errors++))
			fi
		fi
	done <<<"$script_files"

	if [[ $errors -gt 0 && "$CHECK_MODE" == "true" ]]; then
		log_error "$errors shell scripts are not executable"
		return 1
	fi
}

validate_json() {
	log_info "Checking JSON formatting..."

	local json_files
	json_files=$(find "$PROJECT_ROOT" -name "*.json" | grep -v ".git")

	if [[ -z "$json_files" ]]; then
		log_info "No JSON files found"
		return 0
	fi

	local errors=0
	while IFS= read -r file; do
		if python3 -m json.tool "$file" >/dev/null 2>&1; then
			log_success "JSON file $file is valid"
		else
			log_error "JSON file $file is invalid"
			((errors++))
		fi
	done <<<"$json_files"

	if [[ $errors -gt 0 ]]; then
		return 1
	fi
}

main() {
	if [[ "$FIX_MODE" == "true" ]]; then
		log_info "Running format fixes..."
	else
		log_info "Running format checks..."
	fi

	local total_errors=0

	format_terraform || ((total_errors++))
	lint_ansible || ((total_errors++))
	format_yaml || ((total_errors++))
	check_shell_scripts || ((total_errors++))
	check_file_permissions || ((total_errors++))
	validate_json || ((total_errors++))

	echo
	if [[ $total_errors -eq 0 ]]; then
		log_success "All format checks passed"
		exit 0
	else
		if [[ "$CHECK_MODE" == "true" ]]; then
			log_error "$total_errors format checks failed"
			log_info "Run with --fix to attempt automatic fixes"
			exit 1
		else
			log_info "Format fixes completed with $total_errors remaining issues"
			exit 0
		fi
	fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
