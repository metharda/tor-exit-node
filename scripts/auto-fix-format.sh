#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
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

fix_newlines() {
	log_info "Fixing missing newlines at end of files..."

	find "$ANSIBLE_DIR" -name "*.yml" -o -name "*.yaml" | while IFS= read -r file; do
		if [[ -f "$file" && -s "$file" ]]; then
			if [[ "$(tail -c1 "$file" | wc -l)" -eq 0 ]]; then
				echo "" >>"$file"
				log_info "Added newline to $file"
			fi
		fi
	done
}

fix_trailing_spaces() {
	log_info "Fixing trailing spaces..."

	find "$ANSIBLE_DIR" -name "*.yml" -o -name "*.yaml" | while IFS= read -r file; do
		if [[ -f "$file" ]]; then
			sed -i '' 's/[[:space:]]*$//' "$file"
			log_info "Fixed trailing spaces in $file"
		fi
	done
}

fix_fqcn() {
	log_info "Fixing FQCN (Fully Qualified Collection Names)..."

	local modules=(
		"wait_for_connection:ansible.builtin.wait_for_connection"
		"apt:ansible.builtin.apt"
		"systemd:ansible.builtin.systemd"
		"debug:ansible.builtin.debug"
		"apt_key:ansible.builtin.apt_key"
		"apt_repository:ansible.builtin.apt_repository"
		"user:ansible.builtin.user"
		"copy:ansible.builtin.copy"
		"get_url:ansible.builtin.get_url"
		"unarchive:ansible.builtin.unarchive"
		"template:ansible.builtin.template"
		"file:ansible.builtin.file"
		"cron:ansible.builtin.cron"
		"uri:ansible.builtin.uri"
		"command:ansible.builtin.command"
		"wait_for:ansible.builtin.wait_for"
		"sysctl:ansible.posix.sysctl"
		"docker_network:community.docker.docker_network"
		"docker_image:community.docker.docker_image"
	)

	find "$ANSIBLE_DIR" -name "*.yml" -o -name "*.yaml" | while IFS= read -r file; do
		if [[ -f "$file" ]]; then
			for module_mapping in "${modules[@]}"; do
				local old_module="${module_mapping%%:*}"
				local new_module="${module_mapping##*:}"

				sed -i '' "s/^\\([[:space:]]*\\)${old_module}:/\\1${new_module}:/" "$file"
			done
			log_info "Fixed FQCN in $file"
		fi
	done
}

fix_handler_names() {
	log_info "Fixing handler names to start with uppercase..."

	find "$ANSIBLE_DIR" -path "*/handlers/main.yml" | while IFS= read -r file; do
		if [[ -f "$file" ]]; then
			sed -i '' 's/name: restart /name: Restart /' "$file"
			sed -i '' 's/name: reload /name: Reload /' "$file"
			log_info "Fixed handler names in $file"
		fi
	done
}

fix_yaml_braces() {
	log_info "Fixing YAML brace spacing..."

	find "$ANSIBLE_DIR" -name "*.yml" -o -name "*.yaml" | while IFS= read -r file; do
		if [[ -f "$file" ]]; then
			sed -i '' 's/{{ *\([^}]*\) *}}/{{ \1 }}/g' "$file"
			log_info "Fixed brace spacing in $file"
		fi
	done
}

fix_ansible_collections() {
	log_info "Adding missing Ansible collections to requirements..."

	local requirements_file="$ANSIBLE_DIR/requirements.yml"

	cat >"$requirements_file" <<'EOF'
---
collections:
  - name: ansible.posix
    version: ">=1.4.0"
  - name: community.docker
    version: ">=3.0.0"
  - name: community.general
    version: ">=5.0.0"
EOF

	log_success "Created $requirements_file"
}

fix_document_start() {
	log_info "Adding document start markers..."

	find "$ANSIBLE_DIR" -name "*.yml" -o -name "*.yaml" | while IFS= read -r file; do
		if [[ -f "$file" ]]; then
			if ! head -1 "$file" | grep -q "^---"; then
				sed -i '' '1i\
---
' "$file"
				log_info "Added document start to $file"
			fi
		fi
	done
}

fix_ignore_errors() {
	log_info "Fixing ignore_errors to use failed_when..."

	find "$ANSIBLE_DIR" -name "*.yml" -o -name "*.yaml" | while IFS= read -r file; do
		if [[ -f "$file" ]]; then
			if grep -q "ignore_errors:" "$file"; then
				log_warn "File $file uses ignore_errors and needs manual review"
			fi
		fi
	done
}

fix_jinja_syntax() {
	log_info "Fixing Jinja syntax errors..."

	find "$ANSIBLE_DIR" -name "*.yml" -o -name "*.yaml" | while IFS= read -r file; do
		if [[ -f "$file" ]]; then
			sed -i '' 's/docker ps | grep tor-relay || echo "not running"/docker ps | grep tor-relay \|\| echo "not running"/' "$file"
			log_info "Fixed Jinja syntax in $file"
		fi
	done
}

main() {
	log_info "Starting automatic format fixes..."

	local backup_dir="/tmp/ansible-backup-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$backup_dir"
	cp -r "$ANSIBLE_DIR" "$backup_dir/"
	log_info "Backup created at $backup_dir"

	fix_newlines
	fix_trailing_spaces
	fix_yaml_braces
	fix_fqcn
	fix_handler_names
	fix_document_start
	fix_ansible_collections
	fix_ignore_errors
	fix_jinja_syntax

	log_success "Automatic fixes completed!"
	log_info "Backup is available at: $backup_dir"
	log_warn "Please review the changes and run 'make format' to verify"
}

main "$@"
