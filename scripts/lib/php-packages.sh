#!/usr/bin/env bash
# Shared PHP 8.4 preparation. Call only after operator approval.
bc_prepare_php84() (
    set -euo pipefail
    local packages=(php8.4-cli php8.4-common php8.4-fpm php8.4-gd php8.4-intl php8.4-mbstring php8.4-xml php8.4-mysql php8.4-redis php8.4-imagick php8.4-zip php8.4-curl php8.4-bcmath php8.4-opcache)
    local missing=() pkg plan answer old_php ini backup
    [ "$EUID" -eq 0 ] || { echo 'ERROR: PHP preparation requires root' >&2; return 1; }
    for pkg in "${packages[@]}"; do
        if [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" != 'install ok installed' ]; then
            missing+=("$pkg")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        apt-get update
        plan="$(apt-get -s --no-remove install "${missing[@]}")"
        printf '%s\n' "$plan"
        if grep -q '^Remv ' <<< "$plan"; then
            echo 'ERROR: Refusing package removal' >&2; return 1
        fi
        read -r -p 'Install missing PHP 8.4 packages? [y/N] ' answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 1
        old_php="$(readlink -f /usr/bin/php || true)"
        DEBIAN_FRONTEND=noninteractive apt-get -y --no-remove install "${missing[@]}"
        if [ -n "$old_php" ] && [ -x "$old_php" ] && [ "$(readlink -f /usr/bin/php)" != "$old_php" ]; then
            update-alternatives --set php "$old_php"
        fi
    fi
    ini=/etc/php/8.4/fpm/conf.d/99-bellcom-display.ini
    if [ ! -e "$ini" ]; then
        read -r -p 'Create Bellcom PHP-FPM upload/memory defaults? [y/N] ' answer
        [[ "$answer" =~ ^[Yy]$ ]] || return 1
        printf '%s\n' 'memory_limit = 1024M' 'post_max_size = 220M' 'upload_max_filesize = 200M' > "$ini"
        chmod 0644 "$ini"
        if ! php-fpm8.4 -t; then
            rm -f "$ini"
            return 1
        fi
    fi
    php-fpm8.4 -t
    systemctl enable --now php8.4-fpm
    systemctl reload php8.4-fpm
)
