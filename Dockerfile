FROM alpine:3.20

LABEL org.opencontainers.image.title="breaking-backups" \
      org.opencontainers.image.description="Sidecar image for encrypted restic backups of Postgres, MySQL/MariaDB, and MongoDB to S3" \
      org.opencontainers.image.source="https://example.local/breaking-backups" \
      org.opencontainers.image.licenses="MIT"

# Install database client tools and utilities
RUN apk add --no-cache \
    bash \
    ca-certificates \
    tzdata \
    su-exec \
    postgresql16-client \
    mariadb-client \
    mongodb-tools \
    curl \
    jq \
    dcron \
    wget

# Install latest Restic (0.18.x) from official releases
RUN ARCH=$(uname -m) && \
    case $ARCH in \
        x86_64) RESTIC_ARCH=amd64 ;; \
        aarch64) RESTIC_ARCH=arm64 ;; \
        armv7l) RESTIC_ARCH=arm ;; \
        *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
    esac && \
    RESTIC_VERSION=0.18.0 && \
    wget -O restic.bz2 "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_${RESTIC_ARCH}.bz2" && \
    bunzip2 restic.bz2 && \
    chmod +x restic && \
    mv restic /usr/local/bin/ && \
    restic version

ENV BACKUP_DIR=/backup \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN mkdir -p /usr/local/bin "$BACKUP_DIR" /var/log && \
    mkdir -p /var/spool/cron/crontabs && \
    chmod 755 /var/spool/cron && \
    chmod 755 /var/spool/cron/crontabs && \
    adduser -D -u 1000 backups && \
    mkdir -p /home/backups && \
    chown -R backups:backups "$BACKUP_DIR" /var/log /home/backups

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/backup"]

USER root
WORKDIR /backup

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]


