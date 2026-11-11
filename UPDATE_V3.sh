#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# OS2Display 2.8.x -> 3.0 updater for Bellcom's classic, non-Docker setup.
#
# Default target is the newest published 3.0 release candidate at the time this
# script was written. Override when a newer/final release exists, for example:
#
#   OS2DISPLAY_VERSION=3.0.0 ./UPDATE_V3.sh display.example.dk
#
# Optional overrides:
#   OS2DISPLAY_REQUIRED_2X_VERSION=2.8.1
#   OS2DISPLAY_2X_PHP_BIN=/usr/bin/php8.3
#   OS2DISPLAY_V3_PHP_BIN=/usr/bin/php8.4
#   OS2DISPLAY_APP_URL=https://display.example.dk
#   OS2DISPLAY_REMOVE_DEPRECATED_FEEDS=1
# -----------------------------------------------------------------------------

TARGET_VERSION="${OS2DISPLAY_VERSION:-3.0.0}"
REQUIRED_2X_VERSION="${OS2DISPLAY_REQUIRED_2X_VERSION:-2.8.1}"
REMOVE_DEPRECATED_FEEDS="${OS2DISPLAY_REMOVE_DEPRECATED_FEEDS:-0}"
DOMAIN="${1:-}"

error() {
    printf '\nERROR: %s\n\n' "$*" >&2
}

info() {
    printf '\n== %s ==\n' "$*"
}


# Bellcom web PHP limits. Emulate the selected Apache/FPM INI + conf.d
# rather than checking CLI defaults. A pool-level FPM override requires review.
check_web_php_limits() {
    local sapi="$1" ini="/etc/php/8.4/$1/php.ini" scan="/etc/php/8.4/$1/conf.d"
    if [ ! -f "$ini" ] || [ ! -d "$scan" ]; then
        printf 'ERROR: PHP 8.4 %s configuration not found\n' "$sapi" >&2
        return 1
    fi
    PHP_INI_SCAN_DIR="$scan" php8.4 -c "$ini" -r '
        $limits = ["memory_limit" => 1024, "post_max_size" => 200, "upload_max_filesize" => 200];
        $toMb = static function ($raw) {
            $raw = trim((string)$raw);
            if ($raw === "-1") return INF;
            if (!preg_match("/^([0-9]+)([KMG]?)$/i", $raw, $m)) return -1;
            return (float)$m[1] * (["" => 1 / 1048576, "K" => 1 / 1024, "M" => 1, "G" => 1024][strtoupper($m[2])]);
        };
        $failed = false;
        foreach ($limits as $key => $minimum) {
            $value = ini_get($key);
            $ok = $toMb($value) >= $minimum;
            printf("%s = %s (minimum %dM): %s\\n", $key, $value, $minimum, $ok ? "OK" : "FAIL");
            if (!$ok) $failed = true;
        }
        if ($toMb(ini_get("post_max_size")) < $toMb(ini_get("upload_max_filesize"))) {
            fwrite(STDERR, "ERROR: post_max_size must be >= upload_max_filesize\\n");
            $failed = true;
        }
        if ($failed) exit(1);
    ' || {
        printf 'ERROR: Set memory_limit=1024M, post_max_size=200M, upload_max_filesize=200M for PHP 8.4 %s\n' "$sapi" >&2
        return 1
    }
    if [ "$sapi" = fpm ] && grep -REq '^[[:space:]]*php_(admin_)?value\[(memory_limit|post_max_size|upload_max_filesize)\]' /etc/php/8.4/fpm/pool.d 2>/dev/null; then
        printf 'ERROR: PHP-FPM pool overrides these limits; review pool settings before continuing\n' >&2
        return 1
    fi
}

need_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "Required command not found: $command_name"
        return 1
    fi
}

set_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp="${file}.tmp"

    awk -v key="$key" -v value="$value" '
        BEGIN { found = 0 }
        $0 ~ "^" key "=" {
            if (!found) {
                print key "=" value
                found = 1
            }
            next
        }
        { print }
        END {
            if (!found) {
                print key "=" value
            }
        }
    ' "$file" > "$tmp"

    mv "$tmp" "$file"
}

patch_vhost_for_v3() {
    local file="$1"
    local backup="$file.pre-v3-$TIMESTAMP"

    [ -f "$file" ] || return 0

    cp -a "$file" "$backup"
    VHOST_BACKUPS+=("$backup")

    python3 - "$file" "$PUBLIC_HTML/public" <<'PYVHOST'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
public = sys.argv[2].rstrip('/')
text = path.read_text()
original = text

# Remove the old 2.x static admin/client Directory blocks. In 3.x both are
# handled by the Symfony application, except for a few static client files.
for name in ('admin', 'client'):
    directory = f'{public}/{name}'
    pattern = re.compile(
        r'(?ms)^\s*<Directory\s+' + re.escape(directory) + r'>\s*$.*?^\s*</Directory>\s*\n?'
    )
    text, count = pattern.subn('', text)
    if count > 1:
        raise SystemExit(
            f'ERROR: More than one <Directory {directory}> block found in {path}'
        )

begin = '# BEGIN OS2Display 3.x client routing'
end = '# END OS2Display 3.x client routing'
block_pattern = re.compile(
    r'(?ms)^\s*' + re.escape(begin) + r'.*?^\s*' + re.escape(end) + r'\s*\n?'
)
text = block_pattern.sub('', text)

# public/client is a real directory in the 3.x artifact because release.json
# and online-check are static files. Without these rules Apache treats /client/
# as a directory and returns 403 instead of handing the React route to Symfony.
client_block = (
    "\n\n   " + begin + "\n"
    "   RewriteEngine On\n"
    "   RewriteCond %{REQUEST_URI} !^/client/release\\.json$\n"
    "   RewriteCond %{REQUEST_URI} !^/client/online-check(?:/|$)\n"
    "   RewriteRule ^/?client(?:/.*)?$ /index.php [END]\n\n"
    f"   <Directory {public}/client/online-check>\n"
    "      Require all granted\n"
    "      Options FollowSymLinks\n"
    "      DirectoryIndex index.html\n"
    "      FallbackResource disabled\n"
    "   </Directory>\n"
    "   " + end + "\n"
)

public_pattern = re.compile(
    r'(?ms)^\s*<Directory\s+' + re.escape(public) + r'>\s*$.*?^\s*</Directory>\s*$'
)
matches = list(public_pattern.finditer(text))
if len(matches) != 1:
    raise SystemExit(
        f'ERROR: Expected exactly one <Directory {public}> block in {path}; found {len(matches)}'
    )

match = matches[0]
text = text[:match.end()] + client_block + text[match.end():]

if text != original:
    path.write_text(text)
    print(f'Patched Apache vhost for OS2Display 3.x: {path}')
else:
    print(f'Apache vhost already has the OS2Display 3.x rules: {path}')
PYVHOST
}
cleanup() {
    if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT"
    fi
}

on_error() {
    local status=$?

    printf '\nUPDATE_V3.sh failed.\n' >&2

    if [ "${DEPLOYED:-0}" -eq 0 ] && [ "${VHOST_PATCHED:-0}" -eq 1 ]; then
        printf 'Restoring Apache vhost files because cutover was not completed.\n' >&2

        local backup
        local original
        for backup in "${VHOST_BACKUPS[@]:-}"; do
            [ -f "$backup" ] || continue
            original="${backup%.pre-v3-$TIMESTAMP}"
            cp -a "$backup" "$original"
        done
    fi

    if [ -n "${DB_BACKUP_FILE:-}" ] && [ -f "$DB_BACKUP_FILE" ]; then
        printf 'Database backup: %s\n' "$DB_BACKUP_FILE" >&2
    fi

    if [ -n "${FILE_BACKUP_FOLDER:-}" ] && [ -d "$FILE_BACKUP_FOLDER" ]; then
        printf 'File backup: %s\n' "$FILE_BACKUP_FOLDER" >&2
    fi

    if [ -n "${OLD_RELEASE_DIR:-}" ] && [ -d "$OLD_RELEASE_DIR" ]; then
        printf 'Previous 2.x tree: %s\n' "$OLD_RELEASE_DIR" >&2
    fi

    return "$status"
}

trap cleanup EXIT
trap on_error ERR

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "help" ] || [ "$DOMAIN" = "-h" ] || [ "$DOMAIN" = "--help" ]; then
    cat <<'USAGE'

OS2Display 2.8.x -> 3.0 updater

Usage:
  ./UPDATE_V3.sh your.domain.com

Optional environment variables:
  OS2DISPLAY_VERSION=3.0.0
  OS2DISPLAY_REQUIRED_2X_VERSION=2.8.1
  OS2DISPLAY_2X_PHP_BIN=/usr/bin/php8.3
  OS2DISPLAY_V3_PHP_BIN=/usr/bin/php8.4
  OS2DISPLAY_APP_URL=https://your.domain.com
  OS2DISPLAY_REMOVE_DEPRECATED_FEEDS=1
  OS2DISPLAY_WEB_ROOT=/var/www/your.domain.com
  OS2DISPLAY_APP_DIR=public
  OS2DISPLAY_SOURCE_REF_DIR=/var/www/your.domain.com/public.v2-backup

USAGE
    if [ -z "$DOMAIN" ]; then
        exit 1
    fi
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    error "UPDATE_V3.sh must be run as root"
    exit 1
fi

for command_name in \
    apache2ctl \
    awk \
    cp \
    curl \
    git \
    grep \
    mysql \
    mysqldump \
    python3 \
    sha256sum \
    sudo \
    tar \
    wget
do
    need_command "$command_name" || exit 1
done

WEB_ROOT="${OS2DISPLAY_WEB_ROOT:-/var/www/$DOMAIN}"
APP_DIR="${OS2DISPLAY_APP_DIR:-public_html}"
BACKUP_FOLDER="/var/www/backup"
if ! [[ "$APP_DIR" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || [ "$APP_DIR" = "." ] || [ "$APP_DIR" = ".." ]; then
    error "Invalid OS2DISPLAY_APP_DIR: $APP_DIR"
    exit 1
fi
if [ ! -d "$WEB_ROOT" ]; then
    error "Web root does not exist: $WEB_ROOT"
    exit 1
fi
WEB_ROOT="$(realpath -e "$WEB_ROOT")"
PUBLIC_HTML="$WEB_ROOT/$APP_DIR"
if [ -L "$PUBLIC_HTML" ]; then
    error "The application directory must not be a symlink: $PUBLIC_HTML"
    exit 1
fi
APP_URL="${OS2DISPLAY_APP_URL:-https://$DOMAIN}"

if [ ! -d "$PUBLIC_HTML" ]; then
    error "Document root does not exist: $PUBLIC_HTML"
    exit 1
fi

if [ ! -d "$PUBLIC_HTML/.git" ]; then
    # Installations from a 2.8.1 git archive have no Git metadata.
    # Validate the deployed code against that tag in the preserved old
    # checkout rather than accepting an unverified version override.
    SOURCE_REF_DIR="${OS2DISPLAY_SOURCE_REF_DIR:-}"
    if [ -z "$SOURCE_REF_DIR" ] || [ ! -d "$SOURCE_REF_DIR/.git" ]; then
        error "2.x archive has no .git: set OS2DISPLAY_SOURCE_REF_DIR to a preserved checkout containing the $REQUIRED_2X_VERSION tag"
        exit 1
    fi
    # Git safety is scoped to this single preserved checkout; do not change
    # system/global safe.directory configuration.
    if ! git -c safe.directory="$SOURCE_REF_DIR" -C "$SOURCE_REF_DIR" rev-parse --verify "refs/tags/$REQUIRED_2X_VERSION^{commit}" >/dev/null; then
        error "Tag $REQUIRED_2X_VERSION is missing or unreadable in $SOURCE_REF_DIR"
        exit 1
    fi
    # composer config allow-plugins.symfony/runtime modifies composer.json
    # during installation, without changing its locked dependencies. Verify
    # composer.lock plus the migration and converter code against the tag.
    for source_file in composer.lock src/Command/Utils/ConvertEnvTo3xCommand.php migrations/Version20260507120000.php; do
        if [ ! -f "$PUBLIC_HTML/$source_file" ]; then
            error "Deployed 2.x file missing: $source_file"
            exit 1
        fi
        if ! git -c safe.directory="$SOURCE_REF_DIR" -C "$SOURCE_REF_DIR" show "$REQUIRED_2X_VERSION:$source_file" | cmp -s - "$PUBLIC_HTML/$source_file"; then
            error "Deployed 2.x file differs from tag $REQUIRED_2X_VERSION: $source_file"
            exit 1
        fi
    done
    CURRENT_VERSION="$REQUIRED_2X_VERSION"
    info "Verified archive-based 2.x deployment against tag $REQUIRED_2X_VERSION"
else
    CURRENT_VERSION="$(git -C "$PUBLIC_HTML" describe --tags --exact-match HEAD 2>/dev/null || true)"
fi

OLD_PHP_BIN="${OS2DISPLAY_2X_PHP_BIN:-}"
if [ -z "$OLD_PHP_BIN" ]; then
    OLD_PHP_BIN="$(command -v php || true)"
fi

V3_PHP_BIN="${OS2DISPLAY_V3_PHP_BIN:-}"
if [ -z "$V3_PHP_BIN" ]; then
    if command -v php8.4 >/dev/null 2>&1; then
        V3_PHP_BIN="$(command -v php8.4)"
    else
        V3_PHP_BIN="$(command -v php || true)"
    fi
fi

if [ -z "$OLD_PHP_BIN" ] || [ ! -x "$OLD_PHP_BIN" ]; then
    error "Could not determine the PHP binary used by the 2.x installation"
    exit 1
fi

if [ -z "$V3_PHP_BIN" ] || [ ! -x "$V3_PHP_BIN" ]; then
    error "Could not find a PHP binary for OS2Display 3.x"
    exit 1
fi

V3_PHP_VERSION_ID="$($V3_PHP_BIN -r 'echo PHP_VERSION_ID;')"
V3_PHP_VERSION="$($V3_PHP_BIN -r 'echo PHP_VERSION;')"

if ! [[ "$V3_PHP_VERSION_ID" =~ ^[0-9]+$ ]] || [ "$V3_PHP_VERSION_ID" -lt 80400 ]; then
    error "OS2Display 3.x requires PHP >= 8.4; $V3_PHP_BIN is PHP $V3_PHP_VERSION"
    exit 1
fi

# Check the extensions needed by the 3.x artifact before any backup/cutover.
# ctype/fileinfo/gd/iconv are direct composer platform requirements. pdo_mysql
# is required by Bellcom's MariaDB/MySQL deployment. rc8 also needs an actual
# Redis client extension because Symfony's Redis provider is built during boot.
MISSING_V3_EXTENSIONS=()
for extension in ctype fileinfo gd iconv pdo_mysql imagick; do
    if ! "$V3_PHP_BIN" -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$extension"; then
        MISSING_V3_EXTENSIONS+=("$extension")
    fi
done

if [ "${#MISSING_V3_EXTENSIONS[@]}" -gt 0 ]; then
    error "PHP $V3_PHP_VERSION is missing required extension(s): ${MISSING_V3_EXTENSIONS[*]}"
    printf 'For Debian/Sury PHP 8.4, the common packages include php8.4-mysql and php8.4-gd.\n' >&2
    exit 1
fi

if ! "$V3_PHP_BIN" -m 2>/dev/null | grep -Eqi '^(redis|relay)$'; then
    error "PHP $V3_PHP_VERSION needs the redis or relay extension for OS2Display $TARGET_VERSION"
    printf 'For Debian/Sury PHP 8.4, install php8.4-redis before running this updater.\n' >&2
    exit 1
fi

if [ "$CURRENT_VERSION" != "$REQUIRED_2X_VERSION" ]; then
    error "Expected existing OS2Display API $REQUIRED_2X_VERSION, found '${CURRENT_VERSION:-unknown}'. Upgrade 2.x first."
    exit 1
fi

info "Preflight"
printf 'Domain:             %s\n' "$DOMAIN"
printf 'Current API:        %s\n' "$CURRENT_VERSION"
printf 'Target 3.x:         %s\n' "$TARGET_VERSION"
printf '2.x PHP:            %s (%s)\n' "$OLD_PHP_BIN" "$($OLD_PHP_BIN -r 'echo PHP_VERSION;')"
printf '3.x PHP:            %s (%s)\n' "$V3_PHP_BIN" "$V3_PHP_VERSION"
printf '3.x PHP modules:    ctype fileinfo gd iconv pdo_mysql imagick + redis/relay: OK\n'
printf 'Application URL:    %s\n' "$APP_URL"
printf 'Application dir:    %s\n' "$PUBLIC_HTML"
if [ -e /etc/apache2/mods-enabled/php8.4.load ]; then
    check_web_php_limits apache2 || exit 1
else
    check_web_php_limits fpm || exit 1
fi

# The Bellcom v2 Apache templates use mod_php directives. If this installation
# still uses that layout, insist that php8.4 is already enabled before cutover.
APACHE_VHOSTS=()
for candidate in \
    "/etc/apache2/sites-available/$DOMAIN.conf" \
    "/etc/apache2/sites-available/$DOMAIN-ssl.conf" \
    "/etc/apache2/sites-enabled/$DOMAIN.conf" \
    "/etc/apache2/sites-enabled/$DOMAIN-ssl.conf"
do
    [ -e "$candidate" ] || continue
    resolved="$(readlink -f "$candidate")"

    already=0
    existing=""
    for existing in "${APACHE_VHOSTS[@]:-}"; do
        if [ "$existing" = "$resolved" ]; then
            already=1
            break
        fi
    done

    if [ "$already" -eq 0 ]; then
        APACHE_VHOSTS+=("$resolved")
    fi
done

if [ "${#APACHE_VHOSTS[@]}" -eq 0 ]; then
    error "Could not find an Apache vhost for $DOMAIN"
    exit 1
fi

if ! apache2ctl -M 2>/dev/null | grep -q '^ rewrite_module'; then
    error "Apache mod_rewrite is required for the OS2Display 3.x /client route. Enable it with a2enmod rewrite before upgrading."
    exit 1
fi

USES_MODPHP_LAYOUT=0
for vhost in "${APACHE_VHOSTS[@]}"; do
    if grep -q 'php_admin_value\|php_value' "$vhost"; then
        USES_MODPHP_LAYOUT=1
        break
    fi
done

if [ "$USES_MODPHP_LAYOUT" -eq 1 ]; then
    if [ ! -e /etc/apache2/mods-enabled/php8.4.load ]; then
        error "The vhost uses mod_php directives, but Apache php8.4 is not enabled. Enable the PHP 8.4 Apache module before running this update."
        exit 1
    fi
fi

cd "$PUBLIC_HTML"

info "2.x migration status"
MIGRATION_STATUS="$(sudo -u www-data "$OLD_PHP_BIN" bin/console doctrine:migrations:status --no-interaction)"
printf '%s\n' "$MIGRATION_STATUS"

if printf '%s\n' "$MIGRATION_STATUS" | grep -Eq '\|[[:space:]]*New[[:space:]]*\|[[:space:]]*[1-9][0-9]*[[:space:]]*\|'; then
    error "Pending 2.x Doctrine migrations found. Apply them before upgrading to 3.x."
    exit 1
fi

if ! sudo -u www-data "$OLD_PHP_BIN" bin/console list --raw | grep -q '^app:utils:convert-env-to-3x '; then
    error "The required 2.8 configuration converter app:utils:convert-env-to-3x is missing"
    exit 1
fi

if [ ! -f "$PUBLIC_HTML/config/jwt/private.pem" ] || [ ! -f "$PUBLIC_HTML/config/jwt/public.pem" ]; then
    error "Existing JWT keypair is missing in $PUBLIC_HTML/config/jwt"
    exit 1
fi

if [ ! -d "$PUBLIC_HTML/public/media" ]; then
    error "Existing media directory is missing: $PUBLIC_HTML/public/media"
    exit 1
fi

TMP_ROOT="$(mktemp -d /tmp/os2display-v3.XXXXXX)"
CONFIG_EXPORT="$TMP_ROOT/env.3x"
DOWNLOAD_DIR="$TMP_ROOT/download"
mkdir -p "$DOWNLOAD_DIR"

info "Exporting 2.x application configuration to 3.x format"
# Convert the loaded Symfony/app environment without HTTP-fetching config.json.
# Bellcom installations may protect /admin/config.json at the web layer, while
# the canonical files are available locally in the existing 2.x tree.
sudo -u www-data "$OLD_PHP_BIN" bin/console app:utils:convert-env-to-3x \
    --output=env \
    --skip-config-json > "$CONFIG_EXPORT"

ADMIN_CONFIG_JSON="$PUBLIC_HTML/admin/config.json"
CLIENT_CONFIG_JSON="$PUBLIC_HTML/client/config.json"

if [ ! -f "$ADMIN_CONFIG_JSON" ]; then
    error "Existing admin config.json is missing: $ADMIN_CONFIG_JSON"
    exit 1
fi

if [ ! -f "$CLIENT_CONFIG_JSON" ]; then
    error "Existing client config.json is missing: $CLIENT_CONFIG_JSON"
    exit 1
fi

info "Converting local 2.x admin/client config.json"
python3 - "$ADMIN_CONFIG_JSON" "$CLIENT_CONFIG_JSON" "$CONFIG_EXPORT" <<'CONFIGPY'
import json
import re
import sys
from pathlib import Path

admin_path = Path(sys.argv[1])
client_path = Path(sys.argv[2])
out_path = Path(sys.argv[3])


def load_json(path):
    try:
        data = json.loads(path.read_text())
    except Exception as exc:
        raise SystemExit(f"ERROR: Could not parse {path}: {exc}")
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: Expected JSON object in {path}")
    return data


def nullish(value):
    return value is None or value == "" or value == "null"


def to_bool(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        v = value.strip().lower()
        if v in ("1", "true", "yes", "on"):
            return True
        if v in ("0", "false", "no", "off"):
            return False
    return None


def quote_env(value):
    value = str(value)
    if re.fullmatch(r"[A-Za-z0-9_./:%@+,=~^?&-]*", value):
        return value
    if "'" not in value:
        return "'" + value + "'"
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$') + '"'


admin = load_json(admin_path)
client = load_json(client_path)
lines = []

value = admin.get("rejseplanenApiKey")
if not nullish(value) and isinstance(value, (str, int, float, bool)):
    lines.append(("ADMIN_REJSEPLANEN_APIKEY", str(value)))

for source, target in (
    ("showScreenStatus", "ADMIN_SHOW_SCREEN_STATUS"),
    ("touchButtonRegions", "ADMIN_TOUCH_BUTTON_REGIONS"),
):
    b = to_bool(admin.get(source))
    if b is not None:
        lines.append((target, "true" if b else "false"))

login_methods = admin.get("loginMethods")
if isinstance(login_methods, list):
    converted = []
    for method in login_methods:
        if not isinstance(method, dict):
            continue
        method = dict(method)
        if "enabled" in method and to_bool(method.get("enabled")) is False:
            continue
        method.pop("enabled", None)
        converted.append(method)
    lines.append((
        "ADMIN_LOGIN_METHODS",
        json.dumps(converted, ensure_ascii=False, separators=(",", ":")),
    ))

if not nullish(admin.get("previewClient")):
    lines.append(("ADMIN_ENHANCED_PREVIEW", "true"))

for source, target in (
    ("loginCheckTimeout", "CLIENT_LOGIN_CHECK_TIMEOUT"),
    ("refreshTokenTimeout", "CLIENT_REFRESH_TOKEN_TIMEOUT"),
    ("releaseTimestampIntervalTimeout", "CLIENT_RELEASE_TIMESTAMP_INTERVAL_TIMEOUT"),
    ("schedulingInterval", "CLIENT_SCHEDULING_INTERVAL"),
):
    value = client.get(source)
    if not nullish(value) and isinstance(value, (str, int, float, bool)):
        lines.append((target, str(value)))

data_strategy = client.get("dataStrategy")
if isinstance(data_strategy, dict):
    config = data_strategy.get("config")
    if isinstance(config, dict):
        value = config.get("interval")
        if not nullish(value) and isinstance(value, (str, int, float, bool)):
            lines.append(("CLIENT_PULL_STRATEGY_INTERVAL", str(value)))

color_scheme = client.get("colorScheme")
if isinstance(color_scheme, dict):
    lines.append((
        "CLIENT_COLOR_SCHEME",
        json.dumps(color_scheme, ensure_ascii=False, separators=(",", ":")),
    ))

b = to_bool(client.get("debug"))
if b is not None:
    lines.append(("CLIENT_DEBUG", "true" if b else "false"))

with out_path.open("a") as fh:
    fh.write("\n###> Admin/client configuration converted from local 2.x config.json ###\n")
    for key, value in lines:
        fh.write(f"{key}={quote_env(value)}\n")
    fh.write("###< Admin/client configuration converted from local 2.x config.json ###\n")
CONFIGPY

for required_key in APP_SECRET DATABASE_URL JWT_PASSPHRASE CORS_ALLOW_ORIGIN; do
    if ! grep -q "^${required_key}=" "$CONFIG_EXPORT"; then
        error "Converted configuration is missing required variable: $required_key"
        exit 1
    fi
done

if ! grep -q '^ADMIN_' "$CONFIG_EXPORT"; then
    error "No ADMIN_* values were converted from $ADMIN_CONFIG_JSON"
    exit 1
fi

if ! grep -q '^CLIENT_' "$CONFIG_EXPORT"; then
    error "No CLIENT_* values were converted from $CLIENT_CONFIG_JSON"
    exit 1
fi

set_env_value "$CONFIG_EXPORT" APP_ENV prod
set_env_value "$CONFIG_EXPORT" APP_DEBUG 0

printf 'PHP Redis/Relay extension detected; keeping Redis cache/session defaults.\n' 

chmod 0600 "$CONFIG_EXPORT"

info "Downloading OS2Display $TARGET_VERSION production artifact"
# Stable release assets moved to the renamed os2display/os2display repository.
if [[ "$TARGET_VERSION" == *-rc* ]]; then
    RELEASE_REPO="os2display/display-api-service"
    ARCHIVE_NAME="display-api-service-$TARGET_VERSION.tar.gz"
else
    RELEASE_REPO="os2display/os2display"
    ARCHIVE_NAME="os2display-$TARGET_VERSION.tar.gz"
fi
ARCHIVE_URL="https://github.com/$RELEASE_REPO/releases/download/$TARGET_VERSION/$ARCHIVE_NAME"
CHECKSUM_URL="https://github.com/$RELEASE_REPO/releases/download/$TARGET_VERSION/checksum.txt"

wget -q --show-progress -O "$DOWNLOAD_DIR/$ARCHIVE_NAME" "$ARCHIVE_URL"
wget -q --show-progress -O "$DOWNLOAD_DIR/checksum.txt" "$CHECKSUM_URL"

EXPECTED_SHA256="$(awk 'NF {print $1; exit}' "$DOWNLOAD_DIR/checksum.txt")"
ACTUAL_SHA256="$(sha256sum "$DOWNLOAD_DIR/$ARCHIVE_NAME" | awk '{print $1}')"

if ! [[ "$EXPECTED_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
    error "Could not read a valid SHA-256 digest from checksum.txt"
    exit 1
fi

if [ "${ACTUAL_SHA256,,}" != "${EXPECTED_SHA256,,}" ]; then
    error "SHA-256 mismatch for $ARCHIVE_NAME (expected $EXPECTED_SHA256, got $ACTUAL_SHA256)"
    exit 1
fi

printf 'SHA-256 OK: %s\n' "$ARCHIVE_NAME"

info "Review before upgrade"
printf 'This is a one-way database/content migration from %s to %s.\n' "$CURRENT_VERSION" "$TARGET_VERSION"
printf 'The script will:\n'
printf '  - back up database and files\n'
printf '  - preserve config/jwt and public/media\n'
printf '  - replace the old API/admin/client layout with the 3.x monorepo artifact\n'
printf '  - replace legacy Apache admin/client rules with 3.x client routing/online-check rules\n'
printf '  - run doctrine:migrations:rollup\n'
printf '  - run app:update\n'
printf '  - report deprecated feed sources\n'

read -r -p 'Continue with backup and upgrade (y/n)? ' REPLY
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    printf '\nUpdate cancelled.\n'
    exit 0
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_FOLDER"

DBUSERNAME=""
DBPASS=""
DBNAME=""
if [ -f "$WEB_ROOT/db.txt" ]; then
    # Existing Bellcom installation configuration.
    # shellcheck disable=SC1090
    . "$WEB_ROOT/db.txt"
fi

if [ -z "${DBNAME:-}" ]; then
    DBNAME="${DOMAIN//./_}"
    DBNAME="${DBNAME//-/_}"
fi
FILE_BACKUP_FOLDER="$BACKUP_FOLDER/${DOMAIN}-${TIMESTAMP}"
DB_BACKUP_FILE="$BACKUP_FOLDER/${DBNAME}-${TIMESTAMP}.sql"

info "Backing up database $DBNAME"
if mysqldump -u root "$DBNAME" > "$DB_BACKUP_FILE" 2>/dev/null; then
    :
elif [ -n "${DBUSERNAME:-}" ] && [ -n "${DBPASS:-}" ] && \
     mysqldump -u "$DBUSERNAME" "-p${DBPASS}" "$DBNAME" > "$DB_BACKUP_FILE"; then
    :
else
    rm -f "$DB_BACKUP_FILE"
    error "Database backup failed"
    exit 1
fi
printf 'Database backup: %s\n' "$DB_BACKUP_FILE"

info "Backing up installation"
cp -a "$WEB_ROOT" "$FILE_BACKUP_FOLDER"
printf 'File backup: %s\n' "$FILE_BACKUP_FOLDER"

STAGE_ROOT="$WEB_ROOT/.$APP_DIR-v3-$TIMESTAMP"
if [ -e "$STAGE_ROOT" ]; then
    error "Stage directory already exists: $STAGE_ROOT"
    exit 1
fi
mkdir -p "$STAGE_ROOT"

tar -xzf "$DOWNLOAD_DIR/$ARCHIVE_NAME" -C "$STAGE_ROOT"

# The production release artifact currently omits the root .env dotfile, but
# Symfony Runtime still requires the base file even when .env.local contains
# all production overrides. Fetch it from the exact same release tag.
if [ ! -f "$STAGE_ROOT/.env" ]; then
    ENV_URL="https://raw.githubusercontent.com/$RELEASE_REPO/$TARGET_VERSION/.env"
    if ! wget -q -O "$STAGE_ROOT/.env" "$ENV_URL"; then
        error "Could not download the base .env from $ENV_URL"
        exit 1
    fi
fi

if [ ! -s "$STAGE_ROOT/.env" ]; then
    error "The staged 3.x .env file is missing or empty"
    exit 1
fi

for required_path in \
    bin/console \
    public/index.php \
    public/build \
    public/release.json \
    public/client/release.json \
    public/client/online-check/index.html \
    vendor/autoload.php
do
    if [ ! -e "$STAGE_ROOT/$required_path" ]; then
        error "3.x artifact is missing expected path: $required_path"
        exit 1
    fi
done

info "Preserving JWT keys and uploaded media"
rm -rf "$STAGE_ROOT/config/jwt"
mkdir -p "$STAGE_ROOT/config/jwt"
cp -a "$PUBLIC_HTML/config/jwt/." "$STAGE_ROOT/config/jwt/"

rm -rf "$STAGE_ROOT/public/media"
mkdir -p "$STAGE_ROOT/public/media"
cp -a "$PUBLIC_HTML/public/media/." "$STAGE_ROOT/public/media/"

install -o root -g www-data -m 0640 "$CONFIG_EXPORT" "$STAGE_ROOT/.env.local"
printf '%s\n' "$TARGET_VERSION" > "$STAGE_ROOT/.os2display-version"
mkdir -p "$STAGE_ROOT/var"

chown -R root:www-data "$STAGE_ROOT"
chown -R www-data:www-data \
    "$STAGE_ROOT/var" \
    "$STAGE_ROOT/public/media" \
    "$STAGE_ROOT/config/jwt"
chmod 0755 "$STAGE_ROOT/bin/console"

info "Checking staged 3.x application"
(
    cd "$STAGE_ROOT"
    sudo -u www-data "$V3_PHP_BIN" bin/console about --env=prod
)

info "Checking staged 3.x database connection"
(
    cd "$STAGE_ROOT"
    sudo -u www-data "$V3_PHP_BIN" bin/console doctrine:query:sql 'SELECT 1' --no-interaction >/dev/null
)
printf 'OK: staged 3.x application can connect to the database.\n'

# Prepare Apache config. The live Apache workers still use the already-loaded
# v2 config until the reload after cutover.
VHOST_BACKUPS=()
VHOST_PATCHED=0
for vhost in "${APACHE_VHOSTS[@]}"; do
    patch_vhost_for_v3 "$vhost"
done
VHOST_PATCHED=1

apache2ctl configtest

DEPLOYED=0
OLD_RELEASE_DIR="$WEB_ROOT/$APP_DIR.v2-$TIMESTAMP"

info "Cutting over to OS2Display $TARGET_VERSION"
mv "$PUBLIC_HTML" "$OLD_RELEASE_DIR"
mv "$STAGE_ROOT" "$PUBLIC_HTML"
DEPLOYED=1

cd "$PUBLIC_HTML"

info "Rolling up 2.x Doctrine migration history"
sudo -u www-data "$V3_PHP_BIN" bin/console doctrine:migrations:rollup --no-interaction

info "Installing 3.x migrations, bundled templates and screen layouts"
sudo -u www-data "$V3_PHP_BIN" bin/console app:update --no-interaction

info "Clearing production cache"
sudo -u www-data "$V3_PHP_BIN" bin/console cache:clear --env=prod --no-debug

info "Deprecated feed source report"
if [ "$REMOVE_DEPRECATED_FEEDS" = "1" ]; then
    sudo -u www-data "$V3_PHP_BIN" bin/console app:feed:remove-deprecated-feed-sources --force
else
    sudo -u www-data "$V3_PHP_BIN" bin/console app:feed:remove-deprecated-feed-sources || true
    printf '\nDeprecated feeds were NOT removed automatically.\n'
    printf 'Re-run with OS2DISPLAY_REMOVE_DEPRECATED_FEEDS=1 only after reviewing the report.\n'
fi

info "Reloading PHP/Apache"
if systemctl is-active --quiet php8.4-fpm 2>/dev/null; then
    systemctl reload-or-restart php8.4-fpm
fi
if [ "$USES_MODPHP_LAYOUT" -eq 1 ]; then
    systemctl restart apache2
else
    systemctl reload apache2
fi

info "Final verification"
sudo -u www-data "$V3_PHP_BIN" bin/console doctrine:migrations:status --no-interaction
sudo -u www-data "$V3_PHP_BIN" bin/console app:templates:list
sudo -u www-data "$V3_PHP_BIN" bin/console app:screen-layouts:list

# First verify the backend directly. This catches Apache routing problems even
# when a reverse proxy has separate access-control rules.
for path in /release.json /client/release.json /client/ /client/online-check/ /config/admin /config/client /admin; do
    if curl --fail --silent --show-error --max-time 20 \
        -H "Host: $DOMAIN" "http://127.0.0.1$path" >/dev/null; then
        printf 'OK local:  %s\n' "$path"
    else
        printf 'WARNING local: %s failed through Apache.\n' "$path" >&2
    fi
done

# Then verify the public path through the reverse proxy. /client/ is important:
# /client/release.json can work while the actual client route is broken.
for path in /release.json /client/release.json /client/ /client/online-check/ /config/admin /config/client /admin; do
    if curl --fail --silent --show-error --location --max-time 20 "$APP_URL$path" >/dev/null; then
        printf 'OK public: %s\n' "$APP_URL$path"
    else
        printf 'WARNING public: %s failed. Check reverse-proxy access rules and logs.\n' "$APP_URL$path" >&2
    fi
done

printf '\nOS2Display 3.x upgrade completed for %s\n' "$DOMAIN"
printf 'Version:          %s\n' "$TARGET_VERSION"
printf 'Database backup:  %s\n' "$DB_BACKUP_FILE"
printf 'File backup:      %s\n' "$FILE_BACKUP_FOLDER"
printf 'Previous 2.x:     %s\n' "$OLD_RELEASE_DIR"
printf '\nDo not remove the 2.x tree or backups until an existing screen has reconnected without re-pairing.\n'

