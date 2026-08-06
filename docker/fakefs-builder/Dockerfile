# A one-shot image, never run as a service -- just the source for
# scripts/build-fakefs.sh, which exports its filesystem and turns it
# into config/cowrie/fs.pickle (see docs/ANTI-DETECTION.md).
#
# IMPORTANT: this image is NOT a honeypot and never runs as a service
# -- it's just a "sample" source of a realistic Debian system to scan.
FROM debian:12-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      nginx mariadb-client php-cli git vim curl wget htop \
      cron logrotate rsyslog openssh-server sudo net-tools \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/www/html /opt/app /home/appuser \
    && echo '<?php phpinfo();' > /var/www/html/info.php \
    && echo 'DB_HOST=localhost' > /opt/app/.env \
    && useradd -m appuser 2>/dev/null || true \
    && (grep -q '^appuser:' /etc/passwd || echo 'appuser:x:1001:1001::/home/appuser:/bin/bash' >> /etc/passwd) \
    && echo webprod03 > /etc/hostname
