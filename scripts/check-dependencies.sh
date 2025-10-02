#!/bin/bash
set -euo pipefail

# Get absolute path to project root
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly REQUIRED_TOOLS=(
	"terraform"
	"ansible"
	"ansible-playbook"
	"ssh-keygen"
	"curl"
	"virsh"
	"qemu-img"
)

readonly OPTIONAL_TOOLS=(
	"ansible-lint"
	"yamllint"
	"shellcheck"
)

INSTALL_MODE=false

if [[ "${1:-}" == "--install" ]]; then
	INSTALL_MODE=true
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

check_command() {
	local cmd="$1"
	local install_cmd="${2:-}"

	if command -v "$cmd" >/dev/null 2>&1; then
		log_success "$cmd is installed"
		return 0
	else
		log_warn "$cmd is not installed"

		if [[ "$INSTALL_MODE" == "true" && -n "$install_cmd" ]]; then
			log_info "Installing $cmd..."
			eval "$install_cmd"
			if command -v "$cmd" >/dev/null 2>&1; then
				log_success "$cmd installed successfully"
				return 0
			else
				log_error "Failed to install $cmd"
				return 1
			fi
		fi
		return 1
	fi
}

install_homebrew_tools() {
	if [[ "$OSTYPE" == "darwin"* ]]; then
		if ! command -v brew >/dev/null 2>&1; then
			log_info "Installing Homebrew..."
			/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

			if [[ -f "/opt/homebrew/bin/brew" ]]; then
				eval "$(/opt/homebrew/bin/brew shellenv)"
			elif [[ -f "/usr/local/bin/brew" ]]; then
				eval "$(/usr/local/bin/brew shellenv)"
			fi
		fi

		check_command "terraform" "brew install terraform"
		check_command "ansible" "brew install ansible"
		check_command "docker" "brew install --cask docker"

		install_python_and_pip
		setup_python_venv
		check_and_install_python_packages

		check_command "shellcheck" "brew install shellcheck"
	fi
}

install_linux_tools() {
	if [[ "$OSTYPE" == "linux-gnu"* ]]; then
		local distro
		distro=$(lsb_release -si 2>/dev/null || cat /etc/os-release | grep "^ID=" | cut -d= -f2 | tr -d '"' || echo "Unknown")

		case "$distro" in
		"Ubuntu" | "Debian" | "ubuntu" | "debian")
			check_command "terraform" "
                    curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
                    sudo apt-add-repository 'deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main'
                    sudo apt-get update && sudo apt-get install terraform
                "

			check_command "ansible" "
                    sudo apt-get update
                    sudo apt-get install -y software-properties-common
                    sudo add-apt-repository --yes --update ppa:ansible/ansible
                    sudo apt-get install -y ansible
                "

			check_command "docker" "
                    curl -fsSL https://get.docker.com -o get-docker.sh
                    sudo sh get-docker.sh
                    sudo usermod -aG docker \$USER
                    rm get-docker.sh
                "

			install_python_and_pip
			setup_python_venv
			check_and_install_python_packages

			check_command "shellcheck" "sudo apt-get install -y shellcheck"
			;;
		*)
			log_warn "Automatic installation not supported for $distro"
			log_info "Please install the required tools manually:"
			echo "  - terraform"
			echo "  - ansible"
			echo "  - docker"
			echo "  - python3, pip3, python3-venv"
			;;
		esac
	fi
}

install_python_and_pip() {
	log_info "Installing Python and pip..."

	if [[ "$OSTYPE" == "darwin"* ]]; then
		if ! command -v brew >/dev/null 2>&1; then
			log_info "Installing Homebrew first..."
			/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
		fi

		if ! command -v python3 >/dev/null 2>&1; then
			brew install python
		fi

		if ! command -v pip3 >/dev/null 2>&1; then
			curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
			python3 get-pip.py
			rm get-pip.py
			export PATH="$HOME/.local/bin:$PATH"
		fi

	elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
		local distro
		distro=$(lsb_release -si 2>/dev/null || cat /etc/os-release | grep "^ID=" | cut -d= -f2 | tr -d '"' || echo "Unknown")

		case "$distro" in
		"Ubuntu" | "Debian" | "ubuntu" | "debian")
			sudo apt-get update
			sudo apt-get install -y python3 python3-pip python3-venv python3-dev
			;;
		"CentOS" | "RedHat" | "Fedora" | "centos" | "rhel" | "fedora")
			if command -v dnf >/dev/null 2>&1; then
				sudo dnf install -y python3 python3-pip python3-venv python3-devel
			else
				sudo yum install -y python3 python3-pip python3-venv python3-devel
			fi
			;;
		*)
			log_warn "Unsupported Linux distribution: $distro"
			log_info "Please install python3, pip3, and python3-venv manually"
			return 1
			;;
		esac
	fi
}

setup_python_venv() {
	local venv_dir="$HOME/.local/tailscale-tor-venv"

	log_info "Setting up Python virtual environment..."

	if [[ ! -d "$venv_dir" ]]; then
		python3 -m venv "$venv_dir"
		log_success "Virtual environment created at $venv_dir"
	fi

	source "$venv_dir/bin/activate"

	pip install --upgrade pip

	echo "$venv_dir/bin/activate" >"$HOME/.tailscale-tor-venv-path"

	log_success "Python virtual environment is ready"
}

check_and_install_python_packages() {
	local packages=("ansible-lint" "yamllint")
	local venv_path=""

	if [[ -f "$HOME/.tailscale-tor-venv-path" ]]; then
		venv_path=$(cat "$HOME/.tailscale-tor-venv-path")
		if [[ -f "$venv_path" ]]; then
			source "$venv_path"
			log_info "Using virtual environment"
		fi
	fi

	for package in "${packages[@]}"; do
		local package_check_name="${package//-/_}"

		if python3 -c "import ${package_check_name}" 2>/dev/null; then
			log_success "Python package $package is available"
		else
			log_warn "Python package $package is not available"
			if [[ "$INSTALL_MODE" == "true" ]]; then
				log_info "Installing $package..."

				if [[ -n "${VIRTUAL_ENV:-}" ]]; then
					pip install "$package"
				else
					if command -v pip3 >/dev/null 2>&1; then
						pip3 install "$package" --user
					elif command -v pip >/dev/null 2>&1; then
						pip install "$package" --user
					else
						log_error "No pip found, cannot install Python packages"
						return 1
					fi
				fi

				if python3 -c "import ${package_check_name}" 2>/dev/null; then
					log_success "$package installed successfully"
				else
					log_warn "$package installation may have failed"
				fi
			fi
		fi
	done
}

check_cloud_cli() {
	log_info "Checking cloud provider CLI tools (optional)..."

	if command -v aws >/dev/null 2>&1; then
		log_success "AWS CLI is installed"
	else
		log_warn "AWS CLI is not installed (optional for AWS deployments)"
	fi

	if command -v gcloud >/dev/null 2>&1; then
		log_success "Google Cloud SDK is installed"
	else
		log_warn "Google Cloud SDK is not installed (optional for GCP deployments)"
	fi

	if command -v az >/dev/null 2>&1; then
		log_success "Azure CLI is installed"
	else
		log_warn "Azure CLI is not installed (optional for Azure deployments)"
	fi
}

check_versions() {
	log_info "Checking tool versions..."

	if command -v terraform >/dev/null 2>&1; then
		terraform version | head -n1
	fi

	if command -v ansible >/dev/null 2>&1; then
		ansible --version | head -n1
	fi

	if command -v docker >/dev/null 2>&1; then
		docker version --format '{{.Client.Version}}' 2>/dev/null || echo "Docker client version unknown"
	fi
}

main() {
	log_info "Checking dependencies for Tailscale Tor Exit Node deployment..."

	local missing_tools=0

	for tool in "${REQUIRED_TOOLS[@]}"; do
		if ! check_command "$tool"; then
			((missing_tools++))
		fi
	done

	if [[ "$INSTALL_MODE" == "true" ]]; then
		if [[ "$OSTYPE" == "darwin"* ]]; then
			install_homebrew_tools
		elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
			install_linux_tools
		fi

		check_and_install_python_packages
	fi

	log_info "Checking optional tools..."
	for tool in "${OPTIONAL_TOOLS[@]}"; do
		check_command "$tool" >/dev/null 2>&1 || true
	done

	check_cloud_cli
	check_versions

	if [[ $missing_tools -gt 0 && "$INSTALL_MODE" == "false" ]]; then
		echo
		log_error "$missing_tools required tools are missing"
		log_info "Run with --install to attempt automatic installation"
		exit 1
	elif [[ $missing_tools -eq 0 ]]; then
		echo
		log_success "All required dependencies are satisfied"
		exit 0
	else
		echo
		log_info "Dependency check completed with automatic installation attempts"
	fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
