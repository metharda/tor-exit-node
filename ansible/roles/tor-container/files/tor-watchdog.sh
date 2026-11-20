#!/bin/bash
# Run by tor-watchdog.timer. Docker's restart policy does not act on failed
# health checks, so this restarts the Tor container when it is unhealthy and
# reinstalls the transparent-proxy rules if something removed them.
set -uo pipefail

status=$(docker inspect --format '{{.State.Health.Status}}' tor-proxy 2>/dev/null || echo missing)
case "$status" in
healthy | starting) ;;
missing)
	echo "tor-proxy container is missing; recreating it"
	(cd /opt/tor-proxy && docker compose up --detach)
	;;
*)
	echo "tor-proxy is $status; restarting it"
	docker restart tor-proxy
	;;
esac

if systemctl is-active --quiet transparent-proxy && ! /usr/local/sbin/transparent-proxy status >/dev/null; then
	echo "transparent-proxy rules are missing; reinstalling them"
	systemctl restart transparent-proxy
fi
