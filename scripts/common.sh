# Shared helpers for the scripts in this directory. Source, don't execute.
# shellcheck shell=bash

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"
ANSIBLE_DIR="$PROJECT_ROOT/ansible"
export PROJECT_ROOT TERRAFORM_DIR ANSIBLE_DIR

if [[ -t 1 ]]; then
	_BLUE=$'\033[34m' _GREEN=$'\033[32m' _YELLOW=$'\033[33m' _RED=$'\033[31m' _BOLD=$'\033[1m' _RESET=$'\033[0m'
else
	_BLUE='' _GREEN='' _YELLOW='' _RED='' _BOLD='' _RESET=''
fi

step() { printf '\n%s==>%s %s%s%s\n' "$_BLUE" "$_RESET" "$_BOLD" "$1" "$_RESET"; }
info() { printf '    %s\n' "$1"; }
ok() { printf '    %s✓%s %s\n' "$_GREEN" "$_RESET" "$1"; }
warn() { printf '    %s!%s %s\n' "$_YELLOW" "$_RESET" "$1"; }
die() {
	printf '%serror:%s %s\n' "$_RED" "$_RESET" "$1" >&2
	exit 1
}

# True when Terraform state holds a deployed VM. (With empty state,
# `terraform output -raw` prints a warning but still exits 0.)
deployed() {
	terraform -chdir="$TERRAFORM_DIR" output -raw vm_ip 2>/dev/null | grep -Eq '^[0-9]+(\.[0-9]+){3}$'
}
