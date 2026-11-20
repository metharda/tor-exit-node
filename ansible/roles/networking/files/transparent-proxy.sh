#!/bin/bash
# Transparent Tor routing for Tailscale exit-node clients.
#
#   start  install the rules (idempotent: removes its own rules first)
#   stop   remove the TCP/DNS redirects but keep the leak guards, so client
#          traffic is dropped rather than forwarded unanonymised
#   status exit 0 when every rule is in place
#
# All rules live in dedicated TOR_* chains. Tables owned by Docker, UFW or
# tailscaled are never flushed.
set -euo pipefail

TS_IF="${TS_IF:-tailscale0}"
TRANS_PORT="${TRANS_PORT:-9040}"
DNS_PORT="${DNS_PORT:-9053}"
LOCAL_DNS_PORT="${LOCAL_DNS_PORT:-9054}"
SOCKS_PORT="${SOCKS_PORT:-9050}"

# Rules are "table|parent chain|match|own chain"; each own chain is jumped to
# from position 1 of its parent.
NAT_RULES=(
	"nat|PREROUTING|-i $TS_IF|TOR_CLIENTS"
	"nat|OUTPUT||TOR_LOCAL_DNS"
)
GUARD_RULES=(
	"filter|INPUT||TOR_INPUT"
	"filter|FORWARD||TOR_FORWARD"
	"filter|OUTPUT||TOR_OUTPUT"
)

remove() {
	local table parent match chain
	for rule in "$@"; do
		IFS='|' read -r table parent match chain <<<"$rule"
		# shellcheck disable=SC2086 # $match is intentionally word-split
		while iptables -t "$table" -D "$parent" $match -j "$chain" 2>/dev/null; do :; done
		iptables -t "$table" -F "$chain" 2>/dev/null || true
		iptables -t "$table" -X "$chain" 2>/dev/null || true
	done
}

hook() {
	local table parent match chain
	for rule in "$@"; do
		IFS='|' read -r table parent match chain <<<"$rule"
		# shellcheck disable=SC2086
		iptables -t "$table" -I "$parent" 1 $match -j "$chain"
	done
}

start() {
	remove "${NAT_RULES[@]}" "${GUARD_RULES[@]}"
	while ip6tables -D FORWARD -i "$TS_IF" -j DROP 2>/dev/null; do :; done

	# Client traffic arriving from the tailnet: DNS (whatever server it is
	# addressed to) -> DNSPort, TCP -> TransPort. TCP to this node itself (SSH,
	# peerapi) or to other tailnet peers is left alone.
	iptables -t nat -N TOR_CLIENTS
	iptables -t nat -A TOR_CLIENTS -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
	iptables -t nat -A TOR_CLIENTS -m addrtype --dst-type LOCAL -j RETURN
	iptables -t nat -A TOR_CLIENTS -d 100.64.0.0/10 -j RETURN
	iptables -t nat -A TOR_CLIENTS -p tcp -j REDIRECT --to-ports "$TRANS_PORT"

	# The VM's own DNS goes through Tor too. This matters for clients: when a
	# device uses this exit node, tailscaled answers its DNS with the VM's
	# resolver.
	iptables -t nat -N TOR_LOCAL_DNS
	iptables -t nat -A TOR_LOCAL_DNS -p udp --dport 53 -j REDIRECT --to-ports "$LOCAL_DNS_PORT"

	# Tor listeners are reachable from loopback and the tailnet only.
	iptables -N TOR_INPUT
	iptables -A TOR_INPUT -i lo -j RETURN
	iptables -A TOR_INPUT -i "$TS_IF" -j RETURN
	iptables -A TOR_INPUT -p tcp -m multiport --dports "$TRANS_PORT,$SOCKS_PORT" -j DROP
	iptables -A TOR_INPUT -p udp --dport "$DNS_PORT" -j DROP

	# Anything a client sends that Tor cannot carry (UDP, ICMP, ...) is
	# rejected instead of being forwarded with the VM's real IP.
	iptables -N TOR_FORWARD
	iptables -A TOR_FORWARD -i "$TS_IF" -j REJECT

	# DNS over TCP cannot be redirected to Tor's UDP-only DNSPort, so it is
	# blocked to stop it bypassing Tor.
	iptables -N TOR_OUTPUT
	iptables -A TOR_OUTPUT -p tcp --dport 53 ! -o lo -j REJECT --reject-with tcp-reset

	ip6tables -I FORWARD 1 -i "$TS_IF" -j DROP

	hook "${GUARD_RULES[@]}" "${NAT_RULES[@]}"
	echo "transparent proxy: rules installed (TCP -> :$TRANS_PORT, DNS -> :$DNS_PORT)"
}

stop() {
	remove "${NAT_RULES[@]}"
	echo "transparent proxy: redirects removed, leak guards left in place"
}

status() {
	local table parent match chain
	for rule in "${NAT_RULES[@]}" "${GUARD_RULES[@]}"; do
		IFS='|' read -r table parent match chain <<<"$rule"
		# shellcheck disable=SC2086
		if ! iptables -t "$table" -C "$parent" $match -j "$chain" >/dev/null 2>&1; then
			echo "missing: $table/$parent -> $chain"
			return 1
		fi
	done
	echo "transparent proxy: all rules present"
}

case "${1:-}" in
start | stop | status) "$1" ;;
*)
	echo "usage: $0 {start|stop|status}" >&2
	exit 2
	;;
esac
