#!/bin/bash

echo "=== DNS Test Script ==="
echo "Date: $(date)"
echo

echo "1. Checking resolv.conf:"
cat /etc/resolv.conf
echo

echo "2. Checking the UDP 53 -> 9053 redirect:"
iptables -t nat -S TORPROXY_OUT | grep -- '--dport 53' || echo "DNS redirect rule missing"
echo

echo "3. Checking Tor DNSPort listener (UDP 9053):"
ss -lun | grep :9053 || echo "No UDP 9053 listener"
echo

echo "4. Testing Tor DNSPort directly (127.0.0.1:9053):"
dig +time=5 +tries=1 @127.0.0.1 -p 9053 check.torproject.org A || echo "Direct Tor DNS failed"
echo

echo "5. Testing system DNS (127.0.0.1:53, redirected to Tor):"
dig +time=5 +tries=1 @127.0.0.1 check.torproject.org A || echo "Localhost DNS failed"
echo

echo "=== Test Complete ==="
