#!/bin/bash
set -euo pipefail

# -------------------------------------------------------------------
# OS2Display release updater
# -------------------------------------------------------------------

ADMIN_VERSION="2.7.0"
API_VERSION="2.8.1"
CLIENT_VERSION="2.3.0"

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    printf "\nNo domain name given\n"
    printf "Usage: ./UPDATE.sh your.domain.com\n"
    printf "For further help type ./UPDATE.sh help\n\n"
    exit 1
fi

if [ "$DOMAIN" = "help" ]; then
    printf "\nOS2Display release updater\n\n"
    printf "Usage:\n"
    printf "  ./UPDATE.sh your.domain.com\n\n"
    printf "Versions:\n"
    printf "  API:    %s\n" "$API_VERSION"
    printf "  Client: %s\n" "$CLIENT_VERSION"
    printf "  Admin:  %s\n\n" "$ADMIN_VERSION"
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    printf "\nERROR: UPDATE.sh must be run as root.\n\n" >&2
    exit 1
fi

WEB_ROOT="/var/www/$DOMAIN"
PUBLIC_HTML="$WEB_ROOT/public_html"
BACKUP_FOLDER="/var/www/backup"

CLIENT_PUBLIC_PATH="$PUBLIC_HTML/public/client"
ADMIN_PUBLIC_PATH="$PUBLIC_HTML/public/admin"

TMP_ROOT=""
CONFIG_BACKUP=""

cleanup() {
    if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT"
    fi

    if [ -n "${CONFIG_BACKUP:-}" ] && [ -d "$CONFIG_BACKUP" ]; then
        rm -rf "$CONFIG_BACKUP"
    fi
}

trap cleanup EXIT

error() {
    printf "\nERROR: %s\n\n" "$*" >&2
}

# Resolve the actual frontend deployment directory while preserving
# the installation's existing layout:
#
#   public/client -> ../client   => deploy into the symlink target
#   public/client/               => deploy directly into that directory
#
# The script never converts a directory to a symlink or vice versa.
resolve_frontend_dir() {
    local public_path="$1"
    local name="$2"
    local resolved=""

    if [ -L "$public_path" ]; then
        resolved="$(readlink -f "$public_path" || true)"

        if [ -z "$resolved" ] || [ ! -d "$resolved" ]; then
            error "$name path is a broken symlink: $public_path"
            return 1
        fi

        printf '%s\n' "$resolved"
        return 0
    fi

    if [ -d "$public_path" ]; then
        printf '%s\n' "$public_path"
        return 0
    fi

    error "$name frontend path does not exist: $public_path"
    return 1
}

CLIENT_DIR="$(resolve_frontend_dir "$CLIENT_PUBLIC_PATH" "Client")"
ADMIN_DIR="$(resolve_frontend_dir "$ADMIN_PUBLIC_PATH" "Admin")"

printf "\nFrontend layout detected\n"

if [ -L "$CLIENT_PUBLIC_PATH" ]; then
    printf "Client: symlink %s -> %s\n" "$CLIENT_PUBLIC_PATH" "$CLIENT_DIR"
else
    printf "Client: directory %s\n" "$CLIENT_DIR"
fi

if [ -L "$ADMIN_PUBLIC_PATH" ]; then
    printf "Admin:  symlink %s -> %s\n" "$ADMIN_PUBLIC_PATH" "$ADMIN_DIR"
else
    printf "Admin:  directory %s\n" "$ADMIN_DIR"
fi

check_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "Required command not found: $command_name"
        exit 1
    fi
}

for command_name in \
    git \
    mysql \
    mysqldump \
    php \
    composer \
    sudo \
    wget \
    tar \
    python3
do
    check_command "$command_name"
done

if [ ! -d "$PUBLIC_HTML" ]; then
    error "Document root does not exist: $PUBLIC_HTML"
    exit 1
fi

if [ ! -d "$PUBLIC_HTML/.git" ]; then
    error "$PUBLIC_HTML is not a Git repository"
    exit 1
fi

printf "\nThe following versions will be installed\n\n"
printf "API    = %s\n" "$API_VERSION"
printf "Client = %s\n" "$CLIENT_VERSION"
printf "Admin  = %s\n\n" "$ADMIN_VERSION"

git config --global --get-all safe.directory 2>/dev/null |
    grep -Fxq "$PUBLIC_HTML" ||
    git config --global --add safe.directory "$PUBLIC_HTML"

cd "$PUBLIC_HTML"

# -------------------------------------------------------------------
# Fetch and preflight
# -------------------------------------------------------------------

printf "Fetching API repository and release tags...\n"

git fetch origin --tags --prune

if ! git rev-parse -q --verify "refs/tags/$API_VERSION" >/dev/null; then
    error "API tag '$API_VERSION' was not found"
    exit 1
fi

printf "OK: API tag %s exists\n" "$API_VERSION"

# We expect these local tracked modifications from previous updates.
# Abort if something else has been changed locally, rather than
# destroying an unknown local modification with git reset --hard.

UNEXPECTED_CHANGES=0

while IFS= read -r line; do
    path="${line:3}"

    case "$path" in
        composer.json)
            ;;
        composer.lock)
            ;;
        config/services.yaml)
            ;;
        migrations/Version2022*.php)
            ;;
        migrations/Version2023*.php)
            ;;
        migrations/Version20240110091802.php)
            ;;
        migrations/Version20240116162235.php)
            ;;
        migrations/Version20240221142818.php)
            ;;
        migrations/Version20240225055224.php)
            ;;
        migrations/Version20240403043527.php)
            ;;
        *)
            printf "ERROR: Unexpected tracked local change: %s\n" "$path" >&2
            UNEXPECTED_CHANGES=1
            ;;
    esac
done < <(git status --porcelain=v1 --untracked-files=no)

if [ "$UNEXPECTED_CHANGES" -ne 0 ]; then
    error "Unexpected tracked changes were found. Update has not been started."
    exit 1
fi

# -------------------------------------------------------------------
# Backup
# -------------------------------------------------------------------

mkdir -p "$BACKUP_FOLDER"

DBPASS=""

if [ -f "$WEB_ROOT/db.txt" ]; then
    # db.txt is an existing trusted installation configuration file.
    # shellcheck disable=SC1090
    . "$WEB_ROOT/db.txt"
else
    printf "WARNING: %s/db.txt was not found\n" "$WEB_ROOT"
fi

if [ -n "${DBNAME:-}" ]; then
    CHECK_DB="$DBNAME"
else
    CHECK_DB="${DOMAIN//./_}"
    CHECK_DB="${CHECK_DB//-/_}"
fi

DB_LIST="$(mysql -u root -Nse 'SHOW DATABASES;' 2>/dev/null || true)"

if [ -z "$DB_LIST" ] && [ -n "${DBPASS:-}" ]; then
    DB_LIST="$(mysql -u root "-p${DBPASS}" -Nse 'SHOW DATABASES;' 2>/dev/null || true)"
fi

DB_EXISTS=0

if printf '%s\n' "$DB_LIST" | grep -Fxq "$CHECK_DB"; then
    DB_EXISTS=1
fi

printf "\nBackup will be created before updating %s.\n" "$DOMAIN"
read -r -p "Continue with backup and update (y/n)? " REPLY

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    printf "\nUpdate cancelled.\n\n"
    exit 0
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
FILE_BACKUP_FOLDER="$BACKUP_FOLDER/${DOMAIN}-${TIMESTAMP}"
DB_BACKUP_FILE="$BACKUP_FOLDER/${CHECK_DB}-${TIMESTAMP}.sql"

if [ "$DB_EXISTS" -eq 1 ]; then
    printf "\nBacking up database %s...\n" "$CHECK_DB"

    if mysqldump -u root "$CHECK_DB" > "$DB_BACKUP_FILE" 2>/dev/null; then
        :
    elif [ -n "${DBPASS:-}" ] &&
         mysqldump -u root "-p${DBPASS}" "$CHECK_DB" > "$DB_BACKUP_FILE"; then
        :
    else
        rm -f "$DB_BACKUP_FILE"
        error "Database backup failed"
        exit 1
    fi

    printf "Database backup: %s\n" "$DB_BACKUP_FILE"
else
    printf "\nWARNING: Database %s was not found; skipping database dump.\n" "$CHECK_DB"
fi

printf "\nBacking up document root...\n"

cp -a "$WEB_ROOT" "$FILE_BACKUP_FOLDER"

printf "File backup: %s\n" "$FILE_BACKUP_FOLDER"

# -------------------------------------------------------------------
# Preserve frontend runtime configuration
# -------------------------------------------------------------------

CONFIG_BACKUP="$(mktemp -d /tmp/os2display-update-config.XXXXXX)"

mkdir -p "$CONFIG_BACKUP/client"
mkdir -p "$CONFIG_BACKUP/admin"

if [ -f "$CLIENT_DIR/config.json" ]; then
    cp -a "$CLIENT_DIR/config.json" "$CONFIG_BACKUP/client/config.json"
fi

if [ -f "$ADMIN_DIR/config.json" ]; then
    cp -a "$ADMIN_DIR/config.json" "$CONFIG_BACKUP/admin/config.json"
fi

if [ -f "$ADMIN_DIR/access-config.json" ]; then
    cp -a "$ADMIN_DIR/access-config.json" "$CONFIG_BACKUP/admin/access-config.json"
fi

# -------------------------------------------------------------------
# API release
# -------------------------------------------------------------------

printf "\nInstalling API release %s\n" "$API_VERSION"

cd "$PUBLIC_HTML"

# All known local tracked changes have been checked above and the
# complete installation has now been backed up.
git reset --hard

git checkout --detach "refs/tags/$API_VERSION"

INSTALLED_API_VERSION="$(git describe --exact-match --tags HEAD 2>/dev/null || true)"

if [ "$INSTALLED_API_VERSION" != "$API_VERSION" ]; then
    error "API checkout verification failed"
    exit 1
fi

printf "OK: API checkout is exactly tag %s\n" "$API_VERSION"

# -------------------------------------------------------------------
# DataFixtures production workaround
# -------------------------------------------------------------------

if ! grep -q "../src/DataFixtures/" config/services.yaml; then
    printf "\nPatching config/services.yaml for DataFixtures\n"

    python3 - <<'PY'
from pathlib import Path

path = Path("config/services.yaml")
lines = path.read_text().splitlines()

new_lines = []
inserted = False

for line in lines:
    new_lines.append(line)

    if not inserted and line.strip() == "- '../src/Tests/'":
        indent = line[:len(line) - len(line.lstrip())]
        new_lines.append(f"{indent}- '../src/DataFixtures/'")
        inserted = True

if not inserted:
    raise SystemExit(
        "ERROR: Could not find '- ../src/Tests/' in config/services.yaml"
    )

path.write_text("\n".join(new_lines) + "\n")
PY
fi

# -------------------------------------------------------------------
# Known old Doctrine migrations
# -------------------------------------------------------------------

printf "\nRemoving old Doctrine migrations that must not run again\n"

rm -f migrations/Version2022*.php
rm -f migrations/Version2023*.php
rm -f migrations/Version20240110091802.php
rm -f migrations/Version20240116162235.php
rm -f migrations/Version20240221142818.php
rm -f migrations/Version20240225055224.php
rm -f migrations/Version20240403043527.php

chown -R www-data:www-data "$PUBLIC_HTML"

# -------------------------------------------------------------------
# Composer / Redis
# -------------------------------------------------------------------

printf "\nInstalling PHP dependencies\n"

cd "$PUBLIC_HTML"

if php -m 2>/dev/null | grep -qi '^redis$'; then
    printf "OK: PHP redis extension is active\n"

elif php -m 2>/dev/null | grep -qi '^relay$'; then
    printf "OK: PHP relay extension is active\n"

elif grep -q '"predis/predis"' composer.json 2>/dev/null; then
    printf "OK: predis/predis is already required by composer.json\n"

else
    printf "Installing predis/predis because PHP Redis/Relay is unavailable\n"

    sudo -u www-data composer require \
        'predis/predis:^3.3' \
        --no-interaction \
        --no-scripts
fi

printf "\nRemoving stale Symfony production cache before Composer auto-scripts\n"
rm -rf "$PUBLIC_HTML/var/cache/prod" "$PUBLIC_HTML/var/cache/prod~"
mkdir -p "$PUBLIC_HTML/var/cache"
chown -R www-data:www-data "$PUBLIC_HTML/var"

sudo -u www-data composer install \
    --optimize-autoloader \
    --no-interaction

printf "\nDoctrine migration status\n"

sudo -u www-data php bin/console doctrine:migrations:status

printf "\nRunning Doctrine migrations\n"

sudo -u www-data php bin/console doctrine:migrations:migrate \
    --no-interaction \
    --allow-no-migration

# -------------------------------------------------------------------
# Frontend release installer
# -------------------------------------------------------------------

TMP_ROOT="$(mktemp -d /tmp/os2display-release.XXXXXX)"

install_frontend_release() {
    local name="$1"
    local version="$2"
    local url="$3"
    local destination="$4"
    local archive_root_name="$5"

    local workdir="$TMP_ROOT/$name"
    local archive="$workdir/release.tar.gz"
    local extract_dir="$workdir/extract"
    local payload=""

    printf "\nInstalling %s %s\n" "$name" "$version"

    mkdir -p "$extract_dir"

    if ! wget -q --show-progress -O "$archive" "$url"; then
        error "Download failed: $url"
        return 1
    fi

    if ! tar -xzf "$archive" -C "$extract_dir"; then
        error "Could not extract $name release"
        return 1
    fi

    if [ -d "$extract_dir/$archive_root_name" ]; then
        payload="$extract_dir/$archive_root_name"
    else
        TOP_LEVEL_DIR_COUNT="$(
            find "$extract_dir" \
                -mindepth 1 \
                -maxdepth 1 \
                -type d |
                wc -l
        )"

        TOP_LEVEL_FILE_COUNT="$(
            find "$extract_dir" \
                -mindepth 1 \
                -maxdepth 1 \
                -type f |
                wc -l
        )"

        if [ "$TOP_LEVEL_DIR_COUNT" -eq 1 ] &&
           [ "$TOP_LEVEL_FILE_COUNT" -eq 0 ]; then
            payload="$(
                find "$extract_dir" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -type d |
                    head -n 1
            )"
        else
            payload="$extract_dir"
        fi
    fi

    if [ ! -d "$payload" ]; then
        error "Could not determine extracted payload for $name"
        return 1
    fi

    rm -rf "$destination"
    mkdir -p "$destination"

    cp -a "$payload"/. "$destination"/

    chown -R www-data:www-data "$destination"

    printf "Installed %s into %s\n" "$name" "$destination"
}

install_frontend_release \
    "display-client" \
    "$CLIENT_VERSION" \
    "https://github.com/os2display/display-client/releases/download/$CLIENT_VERSION/display-client-$CLIENT_VERSION.tar.gz" \
    "$CLIENT_DIR" \
    "client"

install_frontend_release \
    "display-admin-client" \
    "$ADMIN_VERSION" \
    "https://github.com/os2display/display-admin-client/releases/download/$ADMIN_VERSION/display-admin-client-$ADMIN_VERSION.tar.gz" \
    "$ADMIN_DIR" \
    "admin"

# -------------------------------------------------------------------
# Restore runtime configuration
# -------------------------------------------------------------------

if [ -f "$CONFIG_BACKUP/client/config.json" ]; then
    cp -a "$CONFIG_BACKUP/client/config.json" "$CLIENT_DIR/config.json"
fi

if [ -f "$CONFIG_BACKUP/admin/config.json" ]; then
    cp -a "$CONFIG_BACKUP/admin/config.json" "$ADMIN_DIR/config.json"
fi

if [ -f "$CONFIG_BACKUP/admin/access-config.json" ]; then
    cp -a "$CONFIG_BACKUP/admin/access-config.json" "$ADMIN_DIR/access-config.json"
fi

chown -R www-data:www-data "$CLIENT_DIR"
chown -R www-data:www-data "$ADMIN_DIR"

# -------------------------------------------------------------------
# Verify frontend layout
# -------------------------------------------------------------------

printf "\nFrontend deployment completed\n"
printf "Client destination: %s\n" "$CLIENT_DIR"
printf "Admin destination:  %s\n" "$ADMIN_DIR"

# -------------------------------------------------------------------
# Local helper scripts
# -------------------------------------------------------------------

for helper in \
    install_templates.sh \
    install_layouts.sh \
    install_feeds.sh
do
    if [ -f "/var/www/display/scripts/$helper" ]; then
        install \
            -o www-data \
            -g www-data \
            -m 0755 \
            "/var/www/display/scripts/$helper" \
            "$PUBLIC_HTML/$helper"
    else
        printf "WARNING: Missing helper script: /var/www/display/scripts/%s\n" "$helper"
    fi
done

cd "$PUBLIC_HTML"

if [ -x "./install_templates.sh" ]; then
    ./install_templates.sh
else
    error "./install_templates.sh is missing or not executable"
    exit 1
fi

if [ -x "./install_layouts.sh" ]; then
    ./install_layouts.sh
else
    error "./install_layouts.sh is missing or not executable"
    exit 1
fi

chown -R www-data:www-data "$WEB_ROOT"

# -------------------------------------------------------------------
# Final verification
# -------------------------------------------------------------------

printf "\nVerifying installation\n"

cd "$PUBLIC_HTML"

FINAL_API_VERSION="$(git describe --exact-match --tags HEAD 2>/dev/null || true)"

if [ "$FINAL_API_VERSION" != "$API_VERSION" ]; then
    error "Expected API $API_VERSION but found '$FINAL_API_VERSION'"
    exit 1
fi

if [ ! -d "$CLIENT_DIR" ]; then
    error "Client directory is missing: $CLIENT_DIR"
    exit 1
fi

if [ ! -d "$ADMIN_DIR" ]; then
    error "Admin directory is missing: $ADMIN_DIR"
    exit 1
fi

# -d follows symlinks, so this validates both supported layouts.
if [ ! -d "$CLIENT_PUBLIC_PATH" ]; then
    error "Public client path is missing or broken: $CLIENT_PUBLIC_PATH"
    exit 1
fi

if [ ! -d "$ADMIN_PUBLIC_PATH" ]; then
    error "Public admin path is missing or broken: $ADMIN_PUBLIC_PATH"
    exit 1
fi

for config_file in \
    "$CLIENT_DIR/config.json" \
    "$ADMIN_DIR/config.json" \
    "$ADMIN_DIR/access-config.json"
do
    if [ ! -f "$config_file" ]; then
        error "Required runtime config is missing: $config_file"
        exit 1
    fi
done

sudo -u www-data php bin/console about

printf "\nOS2Display update completed successfully for %s\n" "$DOMAIN"
printf "API:    %s\n" "$API_VERSION"
printf "Client: %s\n" "$CLIENT_VERSION"
printf "Admin:  %s\n\n" "$ADMIN_VERSION"

