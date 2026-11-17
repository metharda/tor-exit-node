FROM alpine:3.22
# Fixed uid/gid so the host firewall can exempt Tor's own traffic by uid without
# colliding with a system user on the VM. Created before the tor package, which
# then reuses it.
RUN addgroup -S -g 9001 tor && \
    adduser -S -D -H -u 9001 -G tor -h /var/lib/tor -s /sbin/nologin tor && \
    apk add --no-cache tor curl && \
    mkdir -p /var/lib/tor && \
    chown tor:tor /var/lib/tor && \
    chmod 700 /var/lib/tor
COPY torrc /etc/tor/torrc
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh
USER tor
# Healthy only once Tor builds circuits, not just when a port is open.
HEALTHCHECK --interval=60s --timeout=30s --start-period=300s --retries=3 \
    CMD curl -sf --max-time 25 --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip | grep -q '"IsTor":true'
ENTRYPOINT ["/entrypoint.sh"]
