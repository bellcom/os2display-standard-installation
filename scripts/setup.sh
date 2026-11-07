#!/usr/bin/env bash
# OS2Display host prerequisites (not an OS2Display application installer).
# Supported here: Debian 12/13. Existing applications and PHP versions are preserved.
set -e

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

if [ "$(id -u)" -ne 0 ]; then fail "Run this setup as root (sudo bash /var/setup.sh)"; exit 1; fi
if [ ! -r /etc/os-release ]; then fail "Missing /etc/os-release"; exit 1; fi
. /etc/os-release
if [ "$ID" != "debian" ] || { [ "$VERSION_ID" != "12" ] && [ "$VERSION_ID" != "13" ]; }; then
    fail "Supported by this script: Debian 12/13. Detected: $PRETTY_NAME"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release apache2 git

# Install the Debian Sury PHP repository only when PHP 8.4 is not available.
if ! apt-cache show php8.4-cli >/dev/null 2>&1; then
    echo "Configuring the Sury PHP repository for PHP 8.4"
    apt-get install -y apt-transport-https
    curl -fsSL https://packages.sury.org/php/README.txt -o /tmp/os2display-sury-readme.sh
    bash /tmp/os2display-sury-readme.sh
    apt-get update
fi

apt-get install -y \
    pwgen mariadb-server redis-server redis-tools vim \
    composer zip unzip \
    php8.4-cli php8.4-common php8.4-mbstring php8.4-intl php8.4-gd \
    php8.4-xml php8.4-curl php8.4-mysql php8.4-redis php8.4-opcache \
    php8.4-fpm

# Do not purge previous PHP runtimes or change the system-wide PHP alternative.
a2enmod rewrite proxy_fcgi setenvif
a2enconf php8.4-fpm
systemctl enable --now php8.4-fpm
[ -S /run/php/php8.4-fpm.sock ] || { fail "PHP-FPM socket missing"; exit 1; }
if ! apache2ctl configtest; then
    fail "Apache configuration invalid; not restarting Apache"
    exit 1
fi
systemctl restart apache2

mkdir -p /var/www
if [ -e /var/www/display ]; then
    if [ -d /var/www/display/.git ] &&
       [ "$(git -C /var/www/display remote get-url origin 2>/dev/null)" = "https://github.com/bellcom/os2display-standard-installation.git" ]; then
        echo "/var/www/display already points to Bellcom; leaving existing checkout untouched."
    else
        fail "/var/www/display already exists and was not modified. Check it before proceeding."
        exit 1
    fi
else
    git clone https://github.com/bellcom/os2display-standard-installation.git /var/www/display
fi

printf '\n=== Validation ===\n'
php8.4 -v | head -n 2
php8.4 -m | grep -Ei '^(gd|pdo_mysql|redis|mbstring|intl)$'
redis-cli ping
systemctl is-active php8.4-fpm
apache2ctl configtest
echo "Host prerequisites installed. For existing OS2Display 2.8.1 use UPDATE_V3.sh."
echo "INSTALL.sh is a legacy 2.x installer; do not run it for a fresh OS2Display 3.x deployment."
