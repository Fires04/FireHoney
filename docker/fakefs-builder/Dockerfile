# Jednorazovy, nikdy nespoustemy image -- jen zdroj pro
# scripts/build-fakefs.sh, ktery z neho vyexportuje filesystem a
# vyrobi z nej config/cowrie/fs.pickle (viz docs/ANTI-DETECTION.md).
#
# DULEZITE: tenhle obraz NENI honeypot a nikdy nebezi jako sluzba --
# je to jen zdroj "vzorku" realistickeho Debian systemu k proskenovani.
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
