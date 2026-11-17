#!/bin/sh
set -e

echo "Starting Tor container entrypoint..."

if ! getent group tor >/dev/null 2>&1; then
  echo "Creating tor group..."
  addgroup -S tor
fi

if ! id tor >/dev/null 2>&1; then
  echo "Creating tor user..."
  adduser -S tor -G tor -h /var/lib/tor -s /sbin/nologin
fi

mkdir -p /var/lib/tor /var/log/tor /run/tor

chown -R tor:tor /var/lib/tor /var/log/tor /run/tor
chmod 700 /var/lib/tor

echo "Testing Tor configuration..."
if ! su-exec tor tor --verify-config -f /etc/tor/torrc; then
  echo "ERROR: Tor configuration is invalid!"
  exit 1
fi

echo "Starting Tor daemon..."
exec su-exec tor tor -f /etc/tor/torrc

