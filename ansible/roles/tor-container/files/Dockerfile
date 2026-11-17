FROM alpine:3.18
RUN apk add --no-cache tor netcat-openbsd su-exec && \
    addgroup -S tor 2>/dev/null || true && \
    adduser -S tor -G tor -h /var/lib/tor -s /sbin/nologin 2>/dev/null || true && \
    mkdir -p /var/lib/tor && \
    chown -R tor:tor /var/lib/tor && \
    chmod 700 /var/lib/tor
COPY torrc /etc/tor/torrc
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 9050 9053 9040
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD nc -z localhost 9050 && nc -z localhost 9053 || exit 1
ENTRYPOINT ["/entrypoint.sh"]