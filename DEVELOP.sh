#!/bin/bash
set -euo pipefail

# -------------------------------------------------------------------
# OS2Display DEVELOP updater
#
# Usage:
#   ./DEVELOP.sh your.domain.com
#
# This script updates:
#   - API service from develop branch in existing public_html git repo
#   - display-client from develop branch, built locally
#   - display-admin-client from develop branch, built locally
# -------------------------------------------------------------------

BRANCH="develop"

API_REPO="https://github.com/os2display/display-api-service.git"
CLIENT_REPO="https://github.com/os2display/display-client.git"
ADMIN_REPO="https://github.com/os2display/display-admin-client.git"

DOMAIN="${1:-}"

if [ -z "$DOMAIN" ]; then
    printf "\nNo domain name given\n"
    printf "Usage: ./DEVELOP.sh your.domain.com\n"
    printf "For further help type ./DEVELOP.sh help\n\n"
    exit 1
fi

if [ "$DOMAIN" = "help" ]; then
    printf "\nHelp section\n"
    printf "Usage: ./DEVELOP.sh your.domain.com\n\n"
    printf "This script updates OS2Display from the develop branch instead of tagged releases.\n\n"
    exit 0
fi

WEB_ROOT="/var/www/$DOMAIN"
PUBLIC_HTML="$WEB_ROOT/public_html"
BACKUP_FOLDER="/var/www/backup"
BUILD_ROOT="/tmp/os2display-develop-build"

# -------------------------------------------------------------------
# Dependency check
# -------------------------------------------------------------------

check_command() {
    local command_name="$1"
    local install_hint="$2"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf "\nERROR: Required command not found: %s\n" "$command_name"
        printf "Install suggestion:\n%s\n" "$install_hint"
        MISSING_DEPENDENCIES=1
    fi
}

check_frontend_builder() {
    if command -v yarn >/dev/null 2>&1; then
        FRONTEND_BUILD_METHOD="local yarn"
        return 0
    fi

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        FRONTEND_BUILD_METHOD="docker compose"
        return 0
    fi

    printf "\nERROR: No frontend build tool found.\n"
    printf "Need either local yarn or Docker Compose.\n\n"

    printf "Recommended install with Node/Yarn on Debian:\n"
    printf "apt update\n"
    printf "apt install -y nodejs npm node-corepack\n"
    printf "corepack enable\n"
    printf "corepack prepare yarn@stable --activate\n"
    printf "yarn -v\n\n"

    printf "Fallback Yarn install:\n"
    printf "npm install -g yarn\n"
    printf "yarn -v\n\n"

    printf "Alternative Docker install requires Docker repository first.\n"
    printf "After Docker repo is configured:\n"
    printf "apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin\n\n"

    MISSING_DEPENDENCIES=1
}

MISSING_DEPENDENCIES=0
FRONTEND_BUILD_METHOD=""
REDIS_SUPPORT_AVAILABLE=0
PREDIS_NEEDS_INSTALL=0

printf "\nChecking required dependencies\n"

check_command "git" "apt update && apt install -y git"
check_command "mysql" "apt update && apt install -y default-mysql-client"
check_command "mysqldump" "apt update && apt install -y default-mysql-client"
check_command "php" "apt update && apt install -y php-cli"
check_command "composer" "apt update && apt install -y composer"
check_command "python3" "apt update && apt install -y python3"
check_command "sudo" "apt update && apt install -y sudo"

# Redis is required by the Symfony app configuration.
# Accept either:
#   - PHP redis extension active for CLI PHP
#   - PHP relay extension active for CLI PHP
#   - predis/predis installed in vendor
#   - predis/predis listed in composer.lock
#
# If none is available, do not stop here.
# Composer install section will add predis/predis with --no-scripts first.

PHP_BIN="$(command -v php)"
PHP_VERSION="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"

printf "PHP CLI binary: %s\n" "$PHP_BIN"
printf "PHP CLI version: %s\n" "$("$PHP_BIN" -v | head -n 1 2>/dev/null || true)"

if "$PHP_BIN" -m 2>/dev/null | grep -qi "^redis$"; then
    printf "OK: PHP redis extension is active for CLI PHP\n"
    REDIS_SUPPORT_AVAILABLE=1
elif "$PHP_BIN" -m 2>/dev/null | grep -qi "^relay$"; then
    printf "OK: PHP relay extension is active for CLI PHP\n"
    REDIS_SUPPORT_AVAILABLE=1
elif [ -f "$PUBLIC_HTML/vendor/predis/predis/autoload.php" ] || [ -f "$PUBLIC_HTML/vendor/predis/predis/composer.json" ]; then
    printf "OK: predis/predis is installed in vendor\n"
    REDIS_SUPPORT_AVAILABLE=1
elif [ -f "$PUBLIC_HTML/composer.lock" ] && grep -q '"name": "predis/predis"' "$PUBLIC_HTML/composer.lock"; then
    printf "OK: predis/predis is present in composer.lock and will be installed by composer install\n"
    REDIS_SUPPORT_AVAILABLE=1
else
    printf "\nWARNING: Redis support is not currently available for Symfony.\n"
    printf "The script will install predis/predis with --no-scripts before running full composer install.\n\n"

    printf "Alternative server extension install for current CLI PHP version:\n"
    printf "apt update\n"
    printf "apt install -y php%s-redis\n" "$PHP_VERSION"
    printf "phpenmod -v %s -s cli redis\n" "$PHP_VERSION"
    printf "phpenmod -v %s -s apache2 redis\n" "$PHP_VERSION"
    printf "systemctl restart apache2\n"
    printf "php -m | grep -i redis\n\n"

    PREDIS_NEEDS_INSTALL=1
fi

check_frontend_builder

if [ "$MISSING_DEPENDENCIES" -ne 0 ]; then
    printf "\nOne or more dependencies are missing. Install the missing dependencies and run the script again.\n\n"
    exit 1
fi

printf "\nDependency check OK\n"
printf "Frontend build method: %s\n\n" "$FRONTEND_BUILD_METHOD"

printf "\nThe following branches will be installed in this update\n"
printf "\nApi    = %s\nClient = %s\nAdmin  = %s\n\n" "$BRANCH" "$BRANCH" "$BRANCH"

if [ ! -d "$PUBLIC_HTML" ]; then
    printf "\nERROR: Document root does not exist: %s\n\n" "$PUBLIC_HTML"
    exit 1
fi

if [ ! -d "$PUBLIC_HTML/.git" ]; then
    printf "\nERROR: %s is not a git repository.\n" "$PUBLIC_HTML"
    printf "The API service must already be installed as a git checkout.\n\n"
    exit 1
fi

# -------------------------------------------------------------------
# Backup
# -------------------------------------------------------------------

chown -R www-data: "$PUBLIC_HTML"

if [ -d "$BACKUP_FOLDER" ]; then
    printf "Backup directory already exists in %s.\n" "$BACKUP_FOLDER"
else
    mkdir -p "$BACKUP_FOLDER"
    printf "\nBackup directory created in %s.\n" "$BACKUP_FOLDER"
fi

if [ -f "$WEB_ROOT/db.txt" ]; then
    # Loading DB password. If the file has been removed you will be prompted manually elsewhere.
    mapfile -t a < "$WEB_ROOT/db.txt"
    declare "${a[@]}"
else
    printf "\nWARNING: %s/db.txt was not found. Database backup may fail if DBPASS is unavailable.\n" "$WEB_ROOT"
fi

check_db="${DOMAIN//./_}"

mysql_databases="$(mysql -u root -e 'show databases;' || true)"

if [[ "$mysql_databases" == *"$check_db"* ]]; then
    read -p "Do you want to backup the database and files before update (y/n)? " -n 1 -r
    printf "\n"

    if [[ "$REPLY" =~ ^[Nn]$ ]]; then
        printf "Update cancelled.\n"
        exit 0
    else
        TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
        DB_BACKUP_FILE="$BACKUP_FOLDER/${check_db}-${TIMESTAMP}.sql"
        FILE_BACKUP_FOLDER="$BACKUP_FOLDER/${DOMAIN}-${TIMESTAMP}"

        mysqldump -u root -p"${DBPASS:-}" "$check_db" > "$DB_BACKUP_FILE"
        printf "\nDatabase has been backed up into %s\n" "$DB_BACKUP_FILE"

        cp -R "$WEB_ROOT" "$FILE_BACKUP_FOLDER"
        printf "Document root has been backed up into %s\n" "$FILE_BACKUP_FOLDER"
    fi
fi

# -------------------------------------------------------------------
# API service from develop
# -------------------------------------------------------------------

printf "\nUpdating API service from branch '%s'\n" "$BRANCH"

cd "$PUBLIC_HTML"

git config --global --add safe.directory "$PUBLIC_HTML"

# Stash local changes before switching/pulling.
# The stash is intentionally not popped automatically.
git stash push -m "Auto-stash before DEVELOP.sh update $(date +%Y-%m-%d_%H-%M-%S)" || true

git fetch origin
git checkout "$BRANCH"
git pull --ff-only origin "$BRANCH"

# -------------------------------------------------------------------
# DEVELOP/prod fix:
# DataFixtures depend on hautelook/alice services, which are dev/test only.
# In prod, exclude DataFixtures from automatic Symfony service registration.
# -------------------------------------------------------------------

if [ -f "config/services.yaml" ]; then
    if ! grep -q "../src/DataFixtures/" config/services.yaml; then
        printf "\nPatching config/services.yaml: excluding src/DataFixtures from prod service registration\n"

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
    raise SystemExit("Could not find '- ../src/Tests/' line in config/services.yaml")

path.write_text("\n".join(new_lines) + "\n")
PY
    fi
fi

# -------------------------------------------------------------------
# Migration cleanup
#
# This installation already has old schema objects such as the feed table.
# Some old Doctrine migration files must therefore not be executed again.
# This mirrors the existing UPDATE.sh release behaviour.
# -------------------------------------------------------------------

printf "\nRemoving old Doctrine migration files that should not be executed again\n"

cd "$PUBLIC_HTML"

rm -f migrations/Version2022*.php
rm -f migrations/Version2023*.php
rm -f migrations/Version20240110091802.php
rm -f migrations/Version20240116162235.php
rm -f migrations/Version20240221142818.php
rm -f migrations/Version20240225055224.php
rm -f migrations/Version20240403043527.php

printf "\nChecking that old 2022/2023 migrations are gone\n"
ls -1 migrations/Version2022*.php migrations/Version2023*.php 2>/dev/null || true

printf "\nRemaining migration files:\n"
ls -1 migrations/Version*.php | head -100 || true

printf "\nSkipping manual cache deletion; Symfony Composer scripts will clear cache later\n"

chown -R www-data: "$PUBLIC_HTML"

# -------------------------------------------------------------------
# Composer install
# -------------------------------------------------------------------

printf "\nInstalling PHP dependencies\n"

cd "$PUBLIC_HTML"

# Re-check Redis support AFTER git checkout/pull.
# composer.json/composer.lock may have changed or been stashed above.
if "$PHP_BIN" -m 2>/dev/null | grep -qi "^redis$"; then
    printf "OK: PHP redis extension is active\n"

elif "$PHP_BIN" -m 2>/dev/null | grep -qi "^relay$"; then
    printf "OK: PHP relay extension is active\n"

elif grep -q '"predis/predis"' composer.json 2>/dev/null; then
    printf "OK: predis/predis is already required by composer.json\n"

else
    printf "\nInstalling predis/predis before composer auto-scripts run\n"
    sudo -u www-data composer require predis/predis --no-interaction --no-scripts
fi

sudo -u www-data composer install --optimize-autoloader --no-interaction

printf "\nDoctrine migration status\n"
sudo -u www-data php bin/console doctrine:migrations:status

printf "\nRunning Doctrine migrations\n"
sudo -u www-data php bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration

# -------------------------------------------------------------------
# Helper function for frontend builds
# -------------------------------------------------------------------

build_frontend() {
    local name="$1"
    local repo="$2"
    local destination="$3"

    printf "\nBuilding %s from branch '%s'\n" "$name" "$BRANCH"

    rm -rf "$BUILD_ROOT/$name"
    git clone --branch "$BRANCH" --depth 1 "$repo" "$BUILD_ROOT/$name"

    cd "$BUILD_ROOT/$name"

    # Preserve existing runtime config if it exists.
    local old_config=""
    local old_access_config=""

    if [ -f "$destination/config.json" ]; then
        old_config="$(mktemp)"
        cp "$destination/config.json" "$old_config"
    fi

    if [ -f "$destination/access-config.json" ]; then
        old_access_config="$(mktemp)"
        cp "$destination/access-config.json" "$old_access_config"
    fi

    # Build with docker compose if possible, otherwise fallback to local yarn.
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 && [ -f "docker-compose.yml" ]; then
        printf "Using docker compose build method for %s\n" "$name"
        docker compose run --rm node yarn install
        docker compose run --rm node yarn build
    elif command -v yarn >/dev/null 2>&1; then
        printf "Using local yarn build method for %s\n" "$name"
        yarn install
        yarn build
    else
        printf "\nERROR: Cannot build %s.\n" "$name"
        printf "No supported frontend builder found.\n\n"
        printf "Install Node/Yarn:\n"
        printf "apt update\n"
        printf "apt install -y nodejs npm node-corepack\n"
        printf "corepack enable\n"
        printf "corepack prepare yarn@stable --activate\n"
        printf "yarn -v\n\n"
        exit 1
    fi

    if [ ! -d "build" ]; then
        printf "\nERROR: Build folder was not created for %s.\n\n" "$name"
        exit 1
    fi

    # Add release metadata for develop build.
    # Fetch release tags so develop builds can identify their release baseline.
    git fetch --tags --unshallow >/dev/null 2>&1 || git fetch --tags --force >/dev/null 2>&1 || true
    VERSION="$(git describe --tags --always)"
    COMMIT="$(git rev-parse --short HEAD)"
    printf "{\n  \"releaseTimestamp\": %s,\n  \"releaseTime\": \"%s\",\n  \"releaseVersion\": \"%s\",\n  \"releaseCommit\": \"%s\",\n  \"releaseBranch\": \"%s\"\n}\n" "$(date +%s)" "$(date)" "$VERSION" "$COMMIT" "$BRANCH" > build/release.json

    # If no existing config was present, use example config when available.
    if [ ! -f "build/config.json" ] && [ -f "public/example_config.json" ]; then
        cp public/example_config.json build/config.json
    fi

    if [ ! -f "build/access-config.json" ] && [ -f "public/example-access-config.json" ]; then
        cp public/example-access-config.json build/access-config.json
    fi

    rm -rf "$destination"
    mkdir -p "$destination"
    cp -R build/. "$destination/"

    # Restore existing runtime config after deploy.
    if [ -n "$old_config" ] && [ -f "$old_config" ]; then
        cp "$old_config" "$destination/config.json"
        rm -f "$old_config"
    fi

    if [ -n "$old_access_config" ] && [ -f "$old_access_config" ]; then
        cp "$old_access_config" "$destination/access-config.json"
        rm -f "$old_access_config"
    fi

    chown -R www-data: "$destination"

    printf "%s has been built and installed in %s\n" "$name" "$destination"
}

# -------------------------------------------------------------------
# OS2Display client from develop
# -------------------------------------------------------------------

mkdir -p "$BUILD_ROOT"

build_frontend \
    "display-client" \
    "$CLIENT_REPO" \
    "$PUBLIC_HTML/client"

# -------------------------------------------------------------------
# OS2Display admin client from develop
# -------------------------------------------------------------------

build_frontend \
    "display-admin-client" \
    "$ADMIN_REPO" \
    "$PUBLIC_HTML/admin"

# -------------------------------------------------------------------
# Symfony install commands for templates and layouts
# -------------------------------------------------------------------

# These helper scripts are local installation files and are not part
# of the upstream display-api-service repository. Restore them after
# git stash/checkout so an update cannot remove them.
for helper in install_templates.sh install_layouts.sh install_feeds.sh; do
    if [ -f "/var/www/display/scripts/$helper" ]; then
        install -o www-data -g www-data -m 0755             "/var/www/display/scripts/$helper"             "$PUBLIC_HTML/$helper"
    else
        printf "\nWARNING: Missing helper script: /var/www/display/scripts/%s\n" "$helper"
    fi
done

chown -R www-data: "$WEB_ROOT"

cd "$PUBLIC_HTML"

if [ -x "./install_templates.sh" ]; then
    ./install_templates.sh
else
    printf "\nWARNING: ./install_templates.sh not found or not executable\n"
fi

if [ -x "./install_layouts.sh" ]; then
    ./install_layouts.sh
else
    printf "\nWARNING: ./install_layouts.sh not found or not executable\n"
fi

printf "\nDEVELOP update completed for %s\n\n" "$DOMAIN"
