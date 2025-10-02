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

get_connection_info() {
	if [[ ! -f "$TERRAFORM_DIR/private_key.pem" ]]; then
		log_error "SSH private key not found. Run 'make deploy' first."
		exit 1
	fi

	if [[ ! -f "$ANSIBLE_DIR/inventory.ini" ]]; then
		log_error "Ansible inventory not found. Run 'make deploy' first."
		exit 1
	fi

	PUBLIC_IP=$(cd "$TERRAFORM_DIR" && terraform output -raw public_ip 2>/dev/null)
	VM_USERNAME=$(grep ansible_user "$ANSIBLE_DIR/inventory.ini" | cut -d= -f2)
	SSH_KEY="$TERRAFORM_DIR/private_key.pem"

	if [[ -z "$PUBLIC_IP" ]]; then
		log_error "Could not retrieve public IP from Terraform output"
		exit 1
	fi

	log_info "Connection details:"
	log_info "  Public IP: $PUBLIC_IP"
	log_info "  Username: $VM_USERNAME"
	log_info "  SSH Key: $SSH_KEY"
}

test_ssh_connectivity() {
	log_info "Testing SSH connectivity..."

	if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$VM_USERNAME@$PUBLIC_IP" "echo 'SSH connection successful'"; then
		log_success "SSH connectivity verified"
		return 0
	else
		log_error "SSH connectivity failed"
		return 1
	fi
}

test_tailscale_status() {
	log_info "Checking Tailscale status..."

	local tailscale_output
	tailscale_output=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "sudo tailscale status" 2>/dev/null || echo "")

	if [[ -n "$tailscale_output" ]]; then
		log_success "Tailscale is running"
		echo "$tailscale_output"

		if echo "$tailscale_output" | grep -q "offers exit node"; then
			log_success "Exit node is advertised"
		else
			log_warn "Exit node may not be properly advertised"
		fi
	else
		log_error "Tailscale is not running or not accessible"
		return 1
	fi
}

test_tor_container() {
	log_info "Checking Tor container status..."

	local container_status
	container_status=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "sudo docker ps --filter 'name=tor-proxy' --format 'table {{.Names}}\t{{.Status}}'" 2>/dev/null || echo "")

	if echo "$container_status" | grep -q "tor-proxy"; then
		log_success "Tor container is running"
		echo "$container_status"
	else
		log_error "Tor container is not running"
		return 1
	fi

	log_info "Testing Tor SOCKS connectivity..."
	if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "nc -z 172.20.0.10 9050" 2>/dev/null; then
		log_success "Tor SOCKS port is accessible"
	else
		log_error "Tor SOCKS port is not accessible"
		return 1
	fi

	log_info "Testing Tor DNS connectivity..."
	if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "nc -z 172.20.0.10 9053" 2>/dev/null; then
		log_success "Tor DNS port is accessible"
	else
		log_error "Tor DNS port is not accessible"
		return 1
	fi
}

test_transparent_proxy() {
	log_info "Checking transparent proxy configuration..."

	local iptables_output
	iptables_output=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "sudo iptables -t nat -L TORPROXY -n -v" 2>/dev/null || echo "")

	if [[ -n "$iptables_output" ]]; then
		log_success "Transparent proxy iptables rules are configured"
		local rule_count
		rule_count=$(echo "$iptables_output" | grep -c "REDIRECT\|RETURN" || echo "0")
		log_info "Found $rule_count transparent proxy rules"
	else
		log_error "Transparent proxy iptables rules are missing"
		return 1
	fi

	log_info "Checking IPv6 blocking..."
	local ipv6_status
	ipv6_status=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "sudo ip6tables -L INPUT | grep -c DROP" 2>/dev/null || echo "0")

	if [[ "$ipv6_status" -gt 0 ]]; then
		log_success "IPv6 traffic is blocked"
	else
		log_warn "IPv6 blocking may not be configured properly"
	fi
}

test_dns_configuration() {
	log_info "Checking DNS configuration..."

	local resolv_conf
	resolv_conf=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "cat /etc/resolv.conf" 2>/dev/null || echo "")

	if echo "$resolv_conf" | grep -q "127.0.0.1"; then
		log_success "DNS is configured to use localhost"
	else
		log_warn "DNS configuration may allow leaks"
		echo "resolv.conf content:"
		echo "$resolv_conf"
	fi

	log_info "Testing DNS resolution through Tor..."
	local dns_test
	dns_test=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "nslookup google.com 2>/dev/null | grep -c 'Server:' || echo '0'")

	if [[ "$dns_test" -gt 0 ]]; then
		log_success "DNS resolution is working"
	else
		log_warn "DNS resolution test failed"
	fi
}

test_monitoring() {
	log_info "Checking monitoring setup..."

	log_info "Testing node_exporter accessibility..."
	if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "curl -s http://localhost:9100/metrics | head -5" 2>/dev/null; then
		log_success "Node exporter is accessible and serving metrics"
	else
		log_warn "Node exporter may not be properly configured"
	fi

	local metrics_file="/var/lib/node_exporter/textfile_collector/tor.prom"
	local custom_metrics
	custom_metrics=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "cat $metrics_file 2>/dev/null || echo 'No custom metrics'")

	if [[ "$custom_metrics" != "No custom metrics" ]]; then
		log_success "Custom Tor metrics are available"
		echo "Custom metrics:"
		echo "$custom_metrics"
	else
		log_warn "Custom Tor metrics are not available"
	fi
}

test_security_hardening() {
	log_info "Checking security hardening..."

	log_info "Checking UFW firewall status..."
	local ufw_status
	ufw_status=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "sudo ufw status" 2>/dev/null || echo "")

	if echo "$ufw_status" | grep -q "Status: active"; then
		log_success "UFW firewall is active"
	else
		log_warn "UFW firewall may not be active"
	fi

	log_info "Checking fail2ban status..."
	if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "sudo systemctl is-active fail2ban" 2>/dev/null | grep -q "active"; then
		log_success "Fail2ban is active"
	else
		log_warn "Fail2ban may not be active"
	fi

	log_info "Checking automatic updates..."
	if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "sudo systemctl is-enabled unattended-upgrades" 2>/dev/null | grep -q "enabled"; then
		log_success "Automatic security updates are enabled"
	else
		log_warn "Automatic security updates may not be enabled"
	fi
}

run_leak_tests() {
	log_info "Running leak detection tests..."

	echo
	log_info "=== CLIENT-SIDE LEAK TESTS ==="
	log_info "To test for leaks from a Tailscale client:"
	echo
	echo "1. Connect to your Tailscale network and set this as exit node:"
	echo "   tailscale up --exit-node=$PUBLIC_IP"
	echo
	echo "2. Test Tor routing:"
	echo "   curl https://check.torproject.org"
	echo "   (Should show: Congratulations. This browser is configured to use Tor.)"
	echo
	echo "3. Test IP leak:"
	echo "   curl https://ipinfo.io"
	echo "   (Should show Tor exit node IP, not your real IP)"
	echo
	echo "4. Test DNS leak:"
	echo "   dig @1.1.1.1 google.com"
	echo "   (Should timeout - external DNS blocked)"
	echo
	echo "5. Test IPv6 leak:"
	echo "   curl -6 https://ipv6.google.com"
	echo "   (Should fail - IPv6 disabled)"
	echo

	log_info "=== SERVER-SIDE VERIFICATION ==="
	log_info "Server-side routing verification:"

	local routing_test
	routing_test=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "curl -s --socks5 172.20.0.10:9050 https://check.torproject.org | grep -c 'Congratulations' || echo '0'")

	if [[ "$routing_test" -gt 0 ]]; then
		log_success "Server can route traffic through Tor successfully"
	else
		log_warn "Server Tor routing test inconclusive"
	fi
}

generate_verification_report() {
	log_info "Generating verification report..."

	local report_file="/tmp/tailscale-tor-verification-$(date +%Y%m%d-%H%M%S).txt"

	{
		echo "Tailscale Tor Exit Node Verification Report"
		echo "Generated: $(date)"
		echo "=========================================="
		echo
		echo "Connection Information:"
		echo "  Public IP: $PUBLIC_IP"
		echo "  SSH Command: ssh -i $SSH_KEY $VM_USERNAME@$PUBLIC_IP"
		echo
		echo "Service Status:"
		ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "
            echo '  Tailscale:'
            sudo tailscale status | head -5 || echo '    Not running'
            echo
            echo '  Tor Container:'
            sudo docker ps --filter 'name=tor-proxy' --format 'table {{.Names}}\t{{.Status}}' || echo '    Not running'
            echo
            echo '  System Services:'
            sudo systemctl is-active tailscaled docker ufw fail2ban node_exporter | paste <(echo -e 'tailscaled\ndocker\nufw\nfail2ban\nnode_exporter') - | column -t
            echo
            echo '  Transparent Proxy Rules:'
            sudo iptables -t nat -L TORPROXY -n --line-numbers | head -10 || echo '    Not configured'
        "
	} >"$report_file"

	log_success "Verification report saved to: $report_file"
	echo
	log_info "Report preview:"
	head -20 "$report_file"
}

main() {
	log_info "Starting Tailscale Tor Exit Node verification..."

	get_connection_info

	local test_results=0

	test_ssh_connectivity || ((test_results++))
	test_tailscale_status || ((test_results++))
	test_tor_container || ((test_results++))
	test_transparent_proxy || ((test_results++))
	test_dns_configuration || ((test_results++))
	test_monitoring || ((test_results++))
	test_security_hardening || ((test_results++))

	run_leak_tests
	generate_verification_report

	echo
	if [[ $test_results -eq 0 ]]; then
		log_success "All verification tests passed!"
		log_info "Your Tailscale Tor Exit Node is properly configured and ready for use."
	else
		log_warn "$test_results verification tests failed or showed warnings"
		log_info "Review the output above and check the generated report for details."
	fi

	echo
	log_info "Next steps:"
	echo "1. Authorize the exit node in Tailscale admin: https://login.tailscale.com/admin/machines"
	echo "2. Test from a client: tailscale up --exit-node=$PUBLIC_IP"
	echo "3. Verify Tor routing: curl https://check.torproject.org"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
