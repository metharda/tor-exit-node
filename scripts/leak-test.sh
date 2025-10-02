#!/bin/bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly TERRAFORM_DIR="$PROJECT_ROOT/terraform"
readonly ANSIBLE_DIR="$PROJECT_ROOT/ansible"

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

get_exit_node_info() {
	if [[ ! -f "$TERRAFORM_DIR/private_key.pem" ]] || [[ ! -f "$ANSIBLE_DIR/inventory.ini" ]]; then
		log_error "Deployment files not found. Run 'make deploy' first."
		exit 1
	fi

	PUBLIC_IP=$(cd "$TERRAFORM_DIR" && terraform output -raw public_ip 2>/dev/null)
	VM_USERNAME=$(grep ansible_user "$ANSIBLE_DIR/inventory.ini" | cut -d= -f2)
	SSH_KEY="$TERRAFORM_DIR/private_key.pem"

	if [[ -z "$PUBLIC_IP" ]]; then
		log_error "Could not retrieve public IP from Terraform output"
		exit 1
	fi

	echo "Exit Node IP: $PUBLIC_IP"
	echo "SSH Key: $SSH_KEY"
	echo "Username: $VM_USERNAME"
}

test_server_side_routing() {
	log_info "Testing server-side Tor routing..."

	local tor_check
	tor_check=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"curl -s --socks5 172.20.0.10:9050 https://check.torproject.org" 2>/dev/null || echo "")

	if echo "$tor_check" | grep -q "Congratulations"; then
		log_success "Server can route traffic through Tor"
		return 0
	else
		log_error "Server cannot route traffic through Tor properly"
		return 1
	fi
}

test_dns_leak_prevention() {
	log_info "Testing DNS leak prevention on server..."

	log_info "Checking resolv.conf configuration..."
	local resolv_conf
	resolv_conf=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "cat /etc/resolv.conf" 2>/dev/null)

	if echo "$resolv_conf" | grep -q "127.0.0.1"; then
		log_success "DNS is configured to use localhost"
	else
		log_warn "DNS configuration may allow leaks"
		echo "resolv.conf content:"
		echo "$resolv_conf"
	fi

	log_info "Testing external DNS blocking..."
	local dns_block_test
	dns_block_test=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"timeout 5 dig @8.8.8.8 google.com 2>&1 || echo 'BLOCKED'" 2>/dev/null)

	if echo "$dns_block_test" | grep -q "BLOCKED\|timeout\|connection timed out"; then
		log_success "External DNS queries are blocked"
	else
		log_warn "External DNS queries may not be properly blocked"
		echo "DNS test result: $dns_block_test"
	fi
}

test_ipv6_blocking() {
	log_info "Testing IPv6 blocking on server..."

	local ipv6_disabled
	ipv6_disabled=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"sysctl net.ipv6.conf.all.disable_ipv6" 2>/dev/null || echo "")

	if echo "$ipv6_disabled" | grep -q "= 1"; then
		log_success "IPv6 is disabled system-wide"
	else
		log_warn "IPv6 may not be properly disabled"
	fi

	local ipv6_test
	ipv6_test=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"timeout 5 curl -6 https://ipv6.google.com 2>&1 || echo 'BLOCKED'" 2>/dev/null)

	if echo "$ipv6_test" | grep -q "BLOCKED\|Network is unreachable\|timeout"; then
		log_success "IPv6 connections are blocked"
	else
		log_warn "IPv6 connections may not be properly blocked"
	fi
}

test_transparent_proxy_rules() {
	log_info "Testing transparent proxy iptables rules..."

	local iptables_rules
	iptables_rules=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"sudo iptables -t nat -L TORPROXY -n" 2>/dev/null || echo "")

	if [[ -n "$iptables_rules" ]]; then
		local redirect_rules
		redirect_rules=$(echo "$iptables_rules" | grep -c "REDIRECT" || echo "0")

		if [[ $redirect_rules -gt 0 ]]; then
			log_success "Transparent proxy rules are configured ($redirect_rules REDIRECT rules)"
		else
			log_error "No REDIRECT rules found in transparent proxy configuration"
			return 1
		fi
	else
		log_error "TORPROXY chain not found in iptables"
		return 1
	fi

	local tailscale_blocks
	tailscale_blocks=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"sudo iptables -L OUTPUT -n | grep -c '100.64.0.0/10.*DROP' || echo '0'" 2>/dev/null)

	if [[ $tailscale_blocks -gt 0 ]]; then
		log_success "Tailscale direct exit blocking is configured"
	else
		log_warn "Tailscale direct exit blocking may not be configured"
	fi
}

test_container_isolation() {
	log_info "Testing Tor container isolation..."

	local container_user
	container_user=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"docker exec tor-proxy whoami 2>/dev/null || echo 'ERROR'")

	if [[ "$container_user" == "tor" ]]; then
		log_success "Tor container is running as non-root user"
	else
		log_error "Tor container may be running as root"
		return 1
	fi

	local container_caps
	container_caps=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"docker inspect tor-proxy --format '{{.HostConfig.CapDrop}}' 2>/dev/null || echo 'ERROR'")

	if echo "$container_caps" | grep -q "ALL"; then
		log_success "Container capabilities are dropped"
	else
		log_warn "Container capabilities may not be properly restricted"
	fi

	local readonly_root
	readonly_root=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" \
		"docker inspect tor-proxy --format '{{.HostConfig.ReadonlyRootfs}}' 2>/dev/null || echo 'false'")

	if [[ "$readonly_root" == "true" ]]; then
		log_success "Container root filesystem is read-only"
	else
		log_info "Container filesystem is writable (required for Tor operation)"
	fi
}

run_client_instructions() {
	log_info "Client-side leak testing instructions..."
	echo
	echo "=================================="
	echo "CLIENT-SIDE LEAK TESTING COMMANDS"
	echo "=================================="
	echo
	echo "1. Connect to Tailscale and use this exit node:"
	echo "   tailscale up --exit-node=$PUBLIC_IP"
	echo
	echo "2. Test Tor routing (should show Tor confirmation):"
	echo "   curl https://check.torproject.org"
	echo
	echo "3. Test IP leak (should show Tor exit IP, not your real IP):"
	echo "   curl https://ipinfo.io"
	echo "   curl https://icanhazip.com"
	echo
	echo "4. Test DNS leak (should timeout/fail):"
	echo "   dig @1.1.1.1 google.com"
	echo "   dig @8.8.8.8 google.com"
	echo
	echo "5. Test IPv6 leak (should fail):"
	echo "   curl -6 https://ipv6.google.com"
	echo "   curl -6 https://icanhazip.com"
	echo
	echo "6. Test WebRTC leak (in browser console):"
	echo "   Open browser dev tools, go to Console, paste:"
	echo "   navigator.mediaDevices.getUserMedia({video:false,audio:true}).then(stream=>{new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]}).createDataChannel('test');console.log('WebRTC may expose real IP')}).catch(e=>console.log('WebRTC blocked:',e.name))"
	echo
	echo "7. Test geolocation leak:"
	echo "   curl https://ipgeolocation.io/ip-location"
	echo "   (Should show Tor exit node location, not your real location)"
	echo
	echo "8. Multiple IP leak tests:"
	echo "   for i in {1..5}; do curl -s https://icanhazip.com; sleep 2; done"
	echo "   (All results should be different Tor exit IPs)"
	echo
	echo "=================================="
	echo
}

comprehensive_server_test() {
	log_info "Running comprehensive server-side leak tests..."

	local test_failures=0

	test_server_side_routing || ((test_failures++))
	test_dns_leak_prevention || ((test_failures++))
	test_ipv6_blocking || ((test_failures++))
	test_transparent_proxy_rules || ((test_failures++))
	test_container_isolation || ((test_failures++))

	return $test_failures
}

generate_leak_test_report() {
	local test_results="$1"
	local report_file="/tmp/leak-test-report-$(date +%Y%m%d-%H%M%S).txt"

	{
		echo "Tailscale Tor Exit Node - Leak Test Report"
		echo "Generated: $(date)"
		echo "=========================================="
		echo
		echo "Exit Node Information:"
		echo "  Public IP: $PUBLIC_IP"
		echo "  SSH Access: ssh -i $SSH_KEY $VM_USERNAME@$PUBLIC_IP"
		echo
		echo "Server-Side Test Results:"
		echo "  Total Tests: 5"
		echo "  Failed Tests: $test_results"
		echo "  Status: $([[ $test_results -eq 0 ]] && echo "PASS" || echo "FAIL")"
		echo
		echo "Detailed Server Configuration:"
		ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$VM_USERNAME@$PUBLIC_IP" "
            echo 'Tor Container Status:'
            docker ps --filter 'name=tor-proxy' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || echo 'Not running'
            echo
            echo 'Transparent Proxy Rules:'
            sudo iptables -t nat -L TORPROXY -n --line-numbers 2>/dev/null | head -10 || echo 'Not configured'
            echo
            echo 'DNS Configuration:'
            cat /etc/resolv.conf
            echo
            echo 'IPv6 Status:'
            sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 'Cannot check'
            echo
            echo 'Tor Bootstrap Status:'
            docker logs tor-proxy --tail 5 2>/dev/null | grep -i bootstrap || echo 'No bootstrap info'
        "
	} >"$report_file"

	log_success "Leak test report saved to: $report_file"
	echo
	log_info "Report summary:"
	head -15 "$report_file"
}

main() {
	log_info "Starting comprehensive leak detection tests..."

	get_exit_node_info
	echo

	local server_test_results
	comprehensive_server_test
	server_test_results=$?

	echo
	run_client_instructions

	generate_leak_test_report $server_test_results

	echo
	if [[ $server_test_results -eq 0 ]]; then
		log_success "All server-side leak tests passed!"
		log_info "Follow the client-side instructions above to complete leak testing."
	else
		log_warn "$server_test_results server-side tests failed"
		log_info "Fix server-side issues before testing client-side connectivity."
	fi

	echo
	log_info "Security reminders:"
	echo "  - Always verify Tor routing from client: curl https://check.torproject.org"
	echo "  - Monitor for IP leaks: curl https://ipinfo.io"
	echo "  - Test DNS leaks: dig @8.8.8.8 google.com (should timeout)"
	echo "  - Verify IPv6 is blocked: curl -6 https://ipv6.google.com (should fail)"

	exit $server_test_results
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
