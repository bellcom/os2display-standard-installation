#!/usr/bin/env bash
# Bellcom: upgrade an already-installed OS2Display 3 release (not a 2.x migration).
# Usage: bash UPDATE_V3_RELEASE.sh example.org --check
#        OS2DISPLAY_VERSION=3.0.0 bash UPDATE_V3_RELEASE.sh example.org --apply
# This script file runs in a separate bash process; strict mode never changes the calling shell.
set -Eeuo pipefail
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

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

DOMAIN="${1:-}"
MODE="${2:---check}"
VERSION="${OS2DISPLAY_VERSION:-3.0.0}"
ROOT="/var/www/$DOMAIN"
LIVE="$ROOT/public_html"
BACKUP_BASE="/var/www/backup/os2display-v3"
TMP=
STAGE=
BACKUP=
OLD=
SWAPPED=0

cleanup() {
    local status=$?
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf -- "$TMP"; fi
    if [ -n "$STAGE" ] && [ -d "$STAGE" ] && [ "$SWAPPED" -eq 0 ]; then rm -rf -- "$STAGE"; fi
    if [ "$status" -ne 0 ]; then
        printf 'ERROR: Update interrupted (code %s).\n' "$status" >&2
        if [ -n "$BACKUP" ]; then printf 'Backups: %s\n' "$BACKUP" >&2; fi
        if [ "$SWAPPED" -eq 1 ]; then
            printf 'IMPORTANT: Code was switched. Database migrations may already have run.\n' >&2
            printf 'Do NOT restore only code; evaluate database and code together.\n' >&2
            printf 'Previous code: %s\n' "$OLD" >&2
        fi
    fi
}
trap cleanup EXIT

if [ "$EUID" -ne 0 ]; then die 'Run as root'; exit 1; fi
if [ "$MODE" != --check ] && [ "$MODE" != --apply ]; then die 'Use --check or --apply'; exit 1; fi
if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ && "$DOMAIN" == *.* && "$DOMAIN" != *..* ]]; then
    die 'Invalid domain'; exit 1
fi
if ! [[ "$VERSION" =~ ^3\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then die 'Only explicit 3.x release tags supported'; exit 1; fi

for cmd in php8.4 sudo tar sha256sum wget curl apache2ctl mysqldump mysql python3; do
    if ! command -v "$cmd" >/dev/null; then die "Missing tool: $cmd"; exit 1; fi
done
if [ ! -f "$LIVE/.os2display-version" ] || [ ! -s "$LIVE/.env.local" ] ||
   [ ! -s "$LIVE/.env" ] || [ ! -f "$LIVE/bin/console" ] ||
   [ ! -d "$LIVE/config/jwt" ] || [ ! -d "$LIVE/public/media" ]; then
    die "Missing existing V3 release tree/config/JWT/media in $LIVE"; exit 1
fi
CURRENT="$(tr -d '\r\n' < "$LIVE/.os2display-version")"
if ! [[ "$CURRENT" =~ ^3\. ]]; then die "Existing release is not V3: $CURRENT"; exit 1; fi
if [ "$CURRENT" = "$VERSION" ]; then die "Already running $VERSION"; exit 1; fi

for ext in ctype fileinfo gd iconv pdo_mysql redis imagick; do
    if ! php8.4 -r 'exit(extension_loaded($argv[1]) ? 0 : 1);' "$ext"; then
        die "Missing PHP 8.4 extension: $ext"; exit 1
    fi
done
if [ -e /etc/apache2/mods-enabled/php8.4.load ]; then
    check_web_php_limits apache2 || { die 'PHP 8.4 Apache web upload/memory limits too low'; exit 1; }
else
    check_web_php_limits fpm || { die 'PHP-FPM 8.4 web upload/memory limits too low'; exit 1; }
fi
if ! apache2ctl configtest; then die 'Apache configtest failed'; exit 1; fi
if ! sudo -u www-data test -r "$LIVE/bin/console"; then die 'www-data cannot read bin/console'; exit 1; fi
if ! (cd "$LIVE" && sudo -u www-data php8.4 bin/console about --env=prod >/dev/null); then
    die 'Current Symfony installation cannot boot'; exit 1
fi

# Read only the database name via Symfony Dotenv, without printing credentials.
DB="$(php8.4 -r '
require $argv[1]."/vendor/autoload.php";
(new Symfony\Component\Dotenv\Dotenv())->bootEnv($argv[1]."/.env");
$url=$_SERVER["DATABASE_URL"]??$_ENV["DATABASE_URL"]??"";
$p=parse_url($url);
if (!$p || empty($p["path"])) { fwrite(STDERR,"Invalid DATABASE_URL\n"); exit(1); }
echo ltrim($p["path"],"/");
' "$LIVE")" || { die 'Could not resolve database name'; exit 1; }
if ! [[ "$DB" =~ ^[A-Za-z0-9_]+$ ]]; then die 'Unusual database name (manual review required)'; exit 1; fi
if ! mysql -NBe 'SELECT 1' >/dev/null; then die 'Root MariaDB credentials unavailable'; exit 1; fi
if [ "$(mysql -NBe "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$DB'")" != 1 ]; then
    die "Database not found: $DB"; exit 1
fi
printf 'Domain: %s\nCurrent: %s\nTarget: %s\nDatabase: %s\n' "$DOMAIN" "$CURRENT" "$VERSION" "$DB"
printf 'Existing Apache mod_php/FPM configuration will remain unchanged.\n'

if [ "$MODE" = --check ]; then
    printf 'OK: Read-only preflight passed. No changes made.\n'
    exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$BACKUP_BASE/$DOMAIN-$STAMP"
OLD="$ROOT/public_html.before-$VERSION-$STAMP"
STAGE="$ROOT/.public_html.stage-$VERSION-$STAMP"
if [ -e "$BACKUP" ] || [ -e "$OLD" ] || [ -e "$STAGE" ]; then
    die 'Target backup/staging location already exists'; exit 1
fi
SITE_KB="$(du -sk "$LIVE" | awk '{print $1}')"
FREE_KB="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
if [ "$FREE_KB" -lt "$((SITE_KB * 2 + 1048576))" ]; then
    die 'Insufficient disk space for full backup and staged release'; exit 1
fi

TMP="$(mktemp -d /tmp/os2display-v3-update.XXXXXXXX)"
ARCHIVE="os2display-$VERSION.tar.gz"
BASE="https://github.com/os2display/os2display/releases/download/$VERSION"
printf 'Downloading verified upstream release %s\n' "$VERSION"
wget -q --show-progress -O "$TMP/$ARCHIVE" "$BASE/$ARCHIVE"
wget -q -O "$TMP/checksum.txt" "$BASE/checksum.txt"
EXPECTED="$(awk 'NF {print $1; exit}' "$TMP/checksum.txt")"
ACTUAL="$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')"
if ! [[ "$EXPECTED" =~ ^[a-fA-F0-9]{64}$ ]] || [ "${EXPECTED,,}" != "${ACTUAL,,}" ]; then
    die 'Release SHA256 mismatch'; exit 1
fi
# Reject absolute/traversing names and links before extraction.
if ! python3 - "$TMP/$ARCHIVE" <<'PY'
import pathlib,sys,tarfile
with tarfile.open(sys.argv[1],"r:gz") as tf:
    for m in tf.getmembers():
        p=pathlib.PurePosixPath(m.name)
        if p.is_absolute() or ".." in p.parts or not (m.isfile() or m.isdir()):
            raise SystemExit("Unsafe archive member: "+m.name)
PY
then die 'Release archive has unsafe paths or links'; exit 1; fi

mkdir -p "$STAGE"
tar -xzf "$TMP/$ARCHIVE" --no-same-owner -C "$STAGE"
for entry in .env bin/console vendor/autoload.php public/index.php public/release.json public/client/release.json; do
    if [ ! -s "$STAGE/$entry" ]; then die "Missing artifact file: $entry"; exit 1; fi
done

# Preserve the entire existing local configuration/state, not only dotenv.
cp -a "$LIVE/.env.local" "$STAGE/.env.local"
for item in config/jwt public/media; do
    rm -rf -- "$STAGE/$item"
    mkdir -p "$STAGE/$item"
    cp -a "$LIVE/$item/." "$STAGE/$item/"
done
# Extra site-local directories/config need manual review before applying.
for localpath in public/custom templates/custom config/custom; do
    if [ -e "$LIVE/$localpath" ]; then
        die "Custom path present: $localpath. Review and adapt script before upgrade"; exit 1
    fi
done
printf '%s\n' "$VERSION" > "$STAGE/.os2display-version"
mkdir -p "$STAGE/var"
chown -R root:www-data "$STAGE"
chmod 0750 "$STAGE"
chmod -R g+rX "$STAGE"
chmod 0640 "$STAGE/.env.local"
chown -R www-data:www-data "$STAGE/var" "$STAGE/config/jwt" "$STAGE/public/media"

printf 'Checking staged Symfony and DB read access...\n'
if ! (cd "$STAGE" &&
      sudo -u www-data php8.4 bin/console about --env=prod >/dev/null &&
      sudo -u www-data php8.4 bin/console doctrine:query:sql 'SELECT 1' --no-interaction >/dev/null); then
    die 'Staged application preflight failed'; exit 1
fi
printf 'Database and full site backup: %s\nOld version remains at: %s\n' "$BACKUP" "$OLD"
read -r -p 'Take backups and perform update (database migrations included)? [y/N] ' CONFIRM
if [ "$CONFIRM" != y ] && [ "$CONFIRM" != Y ]; then echo 'Cancelled'; exit 0; fi

mkdir -p "$BACKUP"
chmod 0700 "$BACKUP"
mysqldump --single-transaction --routines --triggers --events --databases "$DB" > "$BACKUP/database.sql"
if [ ! -s "$BACKUP/database.sql" ]; then die 'Empty database backup'; exit 1; fi
tar -cpf "$BACKUP/public_html.tar" -C "$ROOT" public_html
if [ ! -s "$BACKUP/public_html.tar" ]; then die 'Empty application backup'; exit 1; fi

mv "$LIVE" "$OLD"
if ! mv "$STAGE" "$LIVE"; then
    mv "$OLD" "$LIVE" || printf 'CRITICAL: Cannot restore original application path\n' >&2
    die 'Application switch failed'; exit 1
fi
STAGE=
SWAPPED=1
(
  cd "$LIVE"
  sudo -u www-data php8.4 bin/console app:update --no-interaction
  sudo -u www-data php8.4 bin/console cache:clear --env=prod --no-debug
)
apache2ctl configtest
systemctl reload apache2
for path in /release.json /client/release.json /client/ /client/online-check/ /config/admin /config/client /admin; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: $DOMAIN" -H 'X-Forwarded-Proto: https' "http://127.0.0.1$path")"
    printf '%s %s\n' "$code" "$path"
    if [ "$code" != 200 ]; then die "HTTP check failed for $path"; exit 1; fi
done
printf 'SUCCESS: Updated %s -> %s\nBackup: %s\nOld code: %s\n' "$CURRENT" "$VERSION" "$BACKUP" "$OLD"
