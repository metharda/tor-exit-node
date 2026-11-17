#!/bin/sh
set -e

echo "Testing Tor configuration..."
if ! tor --verify-config -f /etc/tor/torrc; then
  echo "ERROR: Tor configuration is invalid!"
  exit 1
fi

echo "Starting Tor daemon..."
exec tor -f /etc/tor/torrc
