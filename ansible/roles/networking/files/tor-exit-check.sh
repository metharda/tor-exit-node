#!/bin/bash
# Health and leak check for the Tailscale Tor exit node, run on the VM.
# Exit status is 0 when every required check passes; warnings do not fail.
set -uo pipefail

if [[ -t 1 ]]; then
	GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' BOLD=$'\033[1m' RESET=$'\033[0m'
else
	GREEN='' YELLOW='' RED='' BOLD='' RESET=''
fi
failures=0
warnings=0

section() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RESET"; }
pass() { printf '  %sPASS%s  %s\n' "$GREEN" "$RESET" "$1"; }
warn() {
	printf '  %sWARN%s  %s\n' "$YELLOW" "$RESET" "$1"
	warnings=$((warnings + 1))
}
fail() {
	printf '  %sFAIL%s  %s\n' "$RED" "$RESET" "$1"
	failures=$((failures + 1))
}
expect() {
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}
refute() {
	local label="$1"
	shift
	if "$@" >/dev/null 2>&1; then fail "$label"; else pass "$label"; fi
}

section "Tor"
health=$(docker inspect --format '{{.State.Health.Status}}' tor-proxy 2>/dev/null || echo missing)
if [[ "$health" == healthy ]]; then
	pass "tor-proxy container is bootstrapped (health: healthy)"
else
	fail "tor-proxy container health is '$health' (docker logs tor-proxy)"
fi
tor_ip=$(curl -fsS --max-time 60 --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null)
if [[ "$(jq -r .IsTor <<<"$tor_ip" 2>/dev/null)" == true ]]; then
	pass "check.torproject.org confirms Tor (exit IP $(jq -r .IP <<<"$tor_ip"))"
else
	fail "check.torproject.org did not confirm Tor over SOCKS"
fi

section "Transparent proxy"
expect "iptables redirects and leak guards are installed" /usr/local/sbin/transparent-proxy status
# 192.0.2.53 is a reserved documentation address with no DNS server behind it:
# an answer can only come from the redirect to Tor's DNSPort.
expect "DNS sent to any server is answered by Tor" dig +short +time=10 +tries=2 @192.0.2.53 check.torproject.org
expect "the system resolver works through Tor" getent ahostsv4 check.torproject.org
refute "DNS over TCP cannot bypass Tor" dig +tcp +time=3 +tries=1 @1.1.1.1 check.torproject.org
expect "IPv6 is disabled" test "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" = 1

section "Tailscale"
status=$(tailscale status --json 2>/dev/null)
prefs=$(tailscale debug prefs 2>/dev/null)
backend=$(jq -r '.BackendState // "unknown"' <<<"$status" 2>/dev/null)
if [[ "$backend" == Running ]]; then
	pass "connected to the tailnet as $(jq -r '.Self.DNSName | rtrimstr(".")' <<<"$status") ($(jq -r '.Self.TailscaleIPs[0]' <<<"$status"))"
else
	fail "tailscaled state is '${backend:-unknown}'"
fi
expect "exit node is advertised" jq -e '.AdvertiseRoutes // [] | index("0.0.0.0/0")' <<<"$prefs"
expect "tailscaled leaves iptables to the transparent proxy" jq -e '.NetfilterMode == 0' <<<"$prefs"
expect "tailscaled does not manage the system resolver" jq -e '.CorpDNS == false' <<<"$prefs"
if jq -e '.Self.AllowedIPs // [] | index("0.0.0.0/0")' >/dev/null 2>&1 <<<"$status"; then
	pass "exit node is approved in the tailnet"
else
	warn "exit node is not approved yet: https://login.tailscale.com/admin/machines"
fi

echo
if ((failures)); then
	printf '%s%d check(s) failed%s, %d warning(s)\n' "$RED" "$failures" "$RESET" "$warnings"
	exit 1
fi
printf '%sAll checks passed%s, %d warning(s)\n' "$GREEN" "$RESET" "$warnings"
