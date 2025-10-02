#!/bin/bash

set -euo pipefail

readonly LOG_FILE="/var/log/tor-watchdog.log"
readonly TOR_CONTAINER="tor-proxy"
readonly CHECK_INTERVAL=60
readonly RESTART_THRESHOLD=3
readonly CIRCUIT_CHECK_INTERVAL=300

CONSECUTIVE_FAILURES=0

log_message() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

check_container_health() {
	if ! docker ps --filter "name=$TOR_CONTAINER" --filter "status=running" | grep -q "$TOR_CONTAINER"; then
		log_message "ERROR: Tor container is not running"
		return 1
	fi

	local health_status
	health_status=$(docker inspect --format='{{.State.Health.Status}}' "$TOR_CONTAINER" 2>/dev/null || echo "unknown")

	if [[ "$health_status" != "healthy" ]]; then
		log_message "WARNING: Tor container health status is $health_status"
		return 1
	fi

	return 0
}

check_tor_connectivity() {
	if ! docker exec "$TOR_CONTAINER" nc -z localhost 9050 >/dev/null 2>&1; then
		log_message "ERROR: Tor SOCKS port not responding"
		return 1
	fi

	if ! docker exec "$TOR_CONTAINER" nc -z localhost 9053 >/dev/null 2>&1; then
		log_message "ERROR: Tor DNS port not responding"
		return 1
	fi

	return 0
}

check_tor_circuits() {
	local circuit_info
	circuit_info=$(timeout 10 docker exec "$TOR_CONTAINER" sh -c "echo 'GETINFO circuit-status' | nc localhost 9051" 2>/dev/null || echo "")

	if [[ -z "$circuit_info" ]]; then
		log_message "WARNING: Cannot retrieve circuit information"
		return 1
	fi

	local built_circuits
	built_circuits=$(echo "$circuit_info" | grep -c "BUILT" || echo "0")

	if [[ $built_circuits -lt 3 ]]; then
		log_message "WARNING: Only $built_circuits circuits built (minimum 3 recommended)"
		return 1
	fi

	log_message "INFO: $built_circuits circuits built and operational"
	return 0
}

check_tor_bootstrap() {
	local bootstrap_info
	bootstrap_info=$(docker logs "$TOR_CONTAINER" --tail 10 2>/dev/null | grep "Bootstrapped" | tail -1 || echo "")

	if echo "$bootstrap_info" | grep -q "100%"; then
		return 0
	else
		log_message "WARNING: Tor bootstrap may not be complete"
		return 1
	fi
}

check_tor_logs_for_errors() {
	local recent_logs
	recent_logs=$(docker logs "$TOR_CONTAINER" --since 5m 2>&1 || echo "")

	local critical_errors=(
		"Connection refused"
		"Circuit establish timeout"
		"Failed to find node"
		"Directory server failure"
		"Consensus not signed"
		"Clock skew"
	)

	for error in "${critical_errors[@]}"; do
		if echo "$recent_logs" | grep -qi "$error"; then
			log_message "ERROR: Critical error detected in logs: $error"
			return 1
		fi
	done

	return 0
}

restart_tor_container() {
	log_message "Attempting to restart Tor container..."

	cd /opt/tor-proxy || {
		log_message "ERROR: Cannot access Tor directory"
		return 1
	}

	docker compose down || {
		log_message "WARNING: docker-compose down failed, forcing stop"
		docker stop "$TOR_CONTAINER" 2>/dev/null || true
		docker rm "$TOR_CONTAINER" 2>/dev/null || true
	}

	sleep 10

	if ! docker compose up -d; then
		log_message "ERROR: Failed to restart Tor container"
		return 1
	fi

	log_message "Tor container restart initiated, waiting for health check..."

	local wait_count=0
	while [[ $wait_count -lt 30 ]]; do
		sleep 5
		((wait_count++))

		if check_container_health && check_tor_connectivity; then
			log_message "SUCCESS: Tor container successfully restarted and healthy"
			CONSECUTIVE_FAILURES=0
			return 0
		fi
	done

	log_message "ERROR: Tor container restart failed health checks"
	return 1
}

perform_health_checks() {
	local health_ok=true

	if ! check_container_health; then
		health_ok=false
	fi

	if ! check_tor_connectivity; then
		health_ok=false
	fi

	if ! check_tor_bootstrap; then
		health_ok=false
	fi

	if ! check_tor_logs_for_errors; then
		health_ok=false
	fi

	if [[ "$health_ok" == "true" ]]; then
		if [[ $CONSECUTIVE_FAILURES -gt 0 ]]; then
			log_message "INFO: Tor container recovered, resetting failure count"
			CONSECUTIVE_FAILURES=0
		fi
		return 0
	else
		((CONSECUTIVE_FAILURES++))
		log_message "WARNING: Health check failed (consecutive failures: $CONSECUTIVE_FAILURES)"
		return 1
	fi
}

monitor_transparent_proxy() {
	local iptables_rules
	iptables_rules=$(iptables -t nat -L TORPROXY 2>/dev/null | grep -c "REDIRECT\|RETURN" || echo "0")

	if [[ $iptables_rules -lt 5 ]]; then
		log_message "ERROR: Transparent proxy rules missing or incomplete"

		if [[ -x "/opt/iptables-rules.sh" ]]; then
			log_message "Attempting to restore iptables rules..."
			/opt/iptables-rules.sh
		fi
	fi
}

send_alert() {
	local message="$1"
	log_message "ALERT: $message"

	echo "$message" | logger -t tor-watchdog -p daemon.crit

	if command -v mail >/dev/null 2>&1 && [[ -n "${ALERT_EMAIL:-}" ]]; then
		echo "$message" | mail -s "Tor Exit Node Alert" "$ALERT_EMAIL"
	fi
}

main() {
	log_message "Starting Tor watchdog monitoring (PID: $$)"

	while true; do
		if ! perform_health_checks; then
			if [[ $CONSECUTIVE_FAILURES -ge $RESTART_THRESHOLD ]]; then
				log_message "Failure threshold reached, attempting restart..."

				if restart_tor_container; then
					send_alert "Tor container was automatically restarted after $CONSECUTIVE_FAILURES failures"
				else
					send_alert "CRITICAL: Unable to restart Tor container after $CONSECUTIVE_FAILURES failures"

					log_message "Entering emergency mode - will retry in 5 minutes"
					sleep 300
				fi
			fi
		fi

		monitor_transparent_proxy

		if [[ $((RANDOM % (CIRCUIT_CHECK_INTERVAL / CHECK_INTERVAL))) -eq 0 ]]; then
			check_tor_circuits || true
		fi

		sleep $CHECK_INTERVAL
	done
}

cleanup() {
	log_message "Tor watchdog shutting down"
	exit 0
}

trap cleanup SIGTERM SIGINT

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	if [[ $EUID -ne 0 ]]; then
		echo "This script must be run as root"
		exit 1
	fi

	exec > >(tee -a "$LOG_FILE") 2>&1
	main "$@" &
	wait
fi
