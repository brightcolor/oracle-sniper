# oracle-sniper -- container image
#
# Deliberately tiny: the whole program is shell, and its only real
# dependencies are curl and openssl.

FROM alpine:3.22

RUN apk add --no-cache \
        bash \
        curl \
        openssl \
        coreutils \
        util-linux-misc \
        tzdata \
        ca-certificates \
    && rm -rf /var/cache/apk/*

COPY bin/oracle-sniper /usr/local/bin/oracle-sniper
COPY bin/oci-api.sh    /usr/local/lib/oracle-sniper/oci-api.sh
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 0755 /usr/local/bin/oracle-sniper /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/oracle-sniper /var/lib/oracle-sniper

# Where the config and the API key live. Mount a volume here, or let the
# entrypoint build the config from environment variables.
VOLUME ["/etc/oracle-sniper", "/var/lib/oracle-sniper"]

ENV CHECK_INTERVAL_SECONDS=600

# Reports unhealthy once the API stops answering, so an expired key or a
# revoked permission surfaces instead of quietly doing nothing forever.
HEALTHCHECK --interval=5m --timeout=60s --start-period=30s --retries=3 \
    CMD oracle-sniper check >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

LABEL org.opencontainers.image.title="oracle-sniper" \
      org.opencontainers.image.description="Keeps asking Oracle Cloud for an Always Free instance until capacity frees up" \
      org.opencontainers.image.source="https://github.com/brightcolor/oracle-sniper" \
      org.opencontainers.image.licenses="MIT"
