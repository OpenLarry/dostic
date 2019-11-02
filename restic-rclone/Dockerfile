FROM restic/restic:latest

ARG RCLONE_VERSION=current
ARG ARCH=amd64
ENV RCLONE_CONFIG="/config/rclone.conf"

RUN apk -U add ca-certificates wget \
    && rm -rf /var/cache/apk/* \
    && cd /tmp \
    && wget -q http://downloads.rclone.org/rclone-${RCLONE_VERSION}-linux-${ARCH}.zip \
    && unzip /tmp/rclone-${RCLONE_VERSION}-linux-${ARCH}.zip \
    && mv /tmp/rclone-*-linux-${ARCH}/rclone /usr/bin \
    && rm -r /tmp/rclone*

VOLUME ["/config"]
