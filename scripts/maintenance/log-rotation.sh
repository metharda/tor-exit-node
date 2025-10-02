#!/bin/bash

set -euo pipefail

readonly LOG_DIR="/var/log"
readonly TOR_LOG_DIR="/opt/tor-proxy/data"
readonly MAX_LOG_SIZE="50M"
readonly MAX_LOG_FILES=7
readonly MAX_LOG_AGE=30

log_message() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /var/log/log-rotation.log
}

rotate_system_logs() {
	log_message "Starting system log rotation..."

	local logs_to_rotate=(
		"/var/log/auth.log"
		"/var/log/syslog"
		"/var/log/kern.log"
		"/var/log/tor-monitor.log"
		"/var/log/alert-check.log"
	)

	for log_file in "${logs_to_rotate[@]}"; do
		if [[ -f "$log_file" ]]; then
			local log_size
			log_size=$(stat -f%z "$log_file" 2>/dev/null || stat -c%s "$log_file" 2>/dev/null || echo "0")

			if [[ $log_size -gt 52428800 ]]; then
				log_message "Rotating $log_file (size: ${log_size} bytes)"

				for i in $(seq $((MAX_LOG_FILES - 1)) -1 1); do
					if [[ -f "${log_file}.${i}" ]]; then
						mv "${log_file}.${i}" "${log_file}.$((i + 1))"
					fi
				done

				cp "$log_file" "${log_file}.1"
				truncate -s 0 "$log_file"

				chown syslog:adm "${log_file}.1" 2>/dev/null || true
				chmod 640 "${log_file}.1" 2>/dev/null || true
			fi
		fi
	done
}

rotate_docker_logs() {
	log_message "Rotating Docker container logs..."

	local containers
	containers=$(docker ps -q 2>/dev/null || echo "")

	if [[ -n "$containers" ]]; then
		while IFS= read -r container_id; do
			local container_name
			container_name=$(docker inspect --format='{{.Name}}' "$container_id" | sed 's/^.//')

			log_message "Truncating logs for container: $container_name"
			truncate -s 0 "$(docker inspect --format='{{.LogPath}}' "$container_id")" 2>/dev/null || true
		done <<<"$containers"
	fi
}

clean_old_logs() {
	log_message "Cleaning old log files..."

	find /var/log -name "*.log.*" -type f -mtime +$MAX_LOG_AGE -delete 2>/dev/null || true
	find /var/log -name "*.gz" -type f -mtime +$MAX_LOG_AGE -delete 2>/dev/null || true

	if [[ -d "$TOR_LOG_DIR" ]]; then
		find "$TOR_LOG_DIR" -name "*.log" -type f -mtime +$MAX_LOG_AGE -delete 2>/dev/null || true
	fi

	find /tmp -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
}

compress_old_logs() {
	log_message "Compressing old log files..."

	find /var/log -name "*.log.[1-9]" -type f ! -name "*.gz" -exec gzip {} \; 2>/dev/null || true
}

check_disk_space() {
	log_message "Checking disk space..."

	local disk_usage
	disk_usage=$(df / | awk 'NR==2 {print $5}' | sed 's/%//')

	if [[ $disk_usage -gt 80 ]]; then
		log_message "WARNING: Disk usage is ${disk_usage}% - running aggressive cleanup"

		find /var/log -name "*.log.*" -type f -mtime +7 -delete 2>/dev/null || true
		find /tmp -type f -mtime +1 -delete 2>/dev/null || true

		docker system prune -f 2>/dev/null || true
	else
		log_message "Disk usage is ${disk_usage}% - normal"
	fi
}

restart_rsyslog() {
	log_message "Restarting rsyslog service..."
	systemctl restart rsyslog 2>/dev/null || true
}

main() {
	log_message "Starting log rotation maintenance..."

	rotate_system_logs
	rotate_docker_logs
	clean_old_logs
	compress_old_logs
	check_disk_space
	restart_rsyslog

	log_message "Log rotation maintenance completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	if [[ $EUID -ne 0 ]]; then
		echo "This script must be run as root"
		exit 1
	fi

	main "$@"
fi
