FROM alpine:3.22

RUN apk add --no-cache tor netcat-openbsd \
    && install -d -o tor -g tor -m 0700 /var/lib/tor

COPY torrc /etc/tor/torrc

USER tor

# Healthy only once Tor has fully bootstrapped and can build circuits.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD printf 'AUTHENTICATE\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n' \
        | nc -w 5 -U /var/lib/tor/control.sock | grep -q 'PROGRESS=100'

CMD ["tor", "-f", "/etc/tor/torrc"]
