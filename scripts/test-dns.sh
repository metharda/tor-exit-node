#!/bin/bash

echo "=== DNS Test Script ==="
echo "Date: $(date)"
echo

echo "1. Checking resolv.conf:"
cat /etc/resolv.conf
echo

echo "2. Checking tor-dns-forwarder service:"
systemctl status tor-dns-forwarder --no-pager || echo "Service not found"
echo

echo "3. Checking port 53 listener:"
ss -lun | grep :53 || echo "No port 53 listener"
echo

echo "4. Testing direct Tor DNS (172.20.0.10:9053):"
dig +time=2 +tries=1 @172.20.0.10 -p 9053 google.com A || echo "Direct Tor DNS failed"
echo

echo "5. Testing localhost DNS (127.0.0.1:53):"
dig +time=3 +tries=1 @127.0.0.1 google.com A || echo "Localhost DNS failed"
echo

echo "6. Testing system DNS resolution:"
nslookup google.com || echo "System nslookup failed"
echo

echo "7. Testing apt repository access:"
apt-cache policy dnsmasq || echo "Cannot access apt repositories"
echo

echo "=== Test Complete ==="
