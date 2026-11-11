#!/usr/bin/env bash
# Fresh OS2Display 3 deployment (no upgrade, no overwrite).
set -Ee -o pipefail
umask 077
die(){ printf 'ERROR: %s\n' "$*" >&2; }

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

DOMAIN="$1"
VERSION="$OS2DISPLAY_VERSION"
[ -n "$VERSION" ] || VERSION=3.0.0-rc8
[ "$EUID" -eq 0 ] || { die 'Run as root'; exit 1; }
[[ "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ && "$DOMAIN" == *.* && "$DOMAIN" != *..* ]] || { die 'Invalid domain'; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]] || { die 'Invalid version'; exit 1; }
ROOT="/var/www/$DOMAIN"
APP="$ROOT/public_html"
VHOST="/etc/apache2/sites-available/$DOMAIN.conf"
TMP=''
cleanup(){ rc=$?; [ -z "$TMP" ] || rm -rf -- "$TMP"; [ "$rc" -eq 0 ] || die "Stopped ($rc); inspect partial site and database before retrying."; }
trap cleanup EXIT
for c in apache2ctl a2ensite curl mysql openssl php8.4 redis-cli sha256sum sudo systemctl tar wget; do command -v "$c" >/dev/null || { die "Missing: $c"; exit 1; }; done
[ ! -e "$ROOT" ] && [ ! -e "$VHOST" ] || { die 'Site or vhost already exists'; exit 1; }
# Apache serves Symfony through PHP-FPM 8.4; mod_php is neither needed nor supported here.
check_web_php_limits fpm || { die 'PHP-FPM 8.4 web upload/memory limits below Bellcom minimum'; exit 1; }
[ -S /run/php/php8.4-fpm.sock ] || { die 'PHP-FPM 8.4 socket missing: /run/php/php8.4-fpm.sock'; exit 1; }
systemctl is-active --quiet php8.4-fpm || { die 'PHP-FPM 8.4 service not running'; exit 1; }
apache2ctl -M 2>/dev/null | grep -q proxy_fcgi_module || { die 'Apache mod_proxy_fcgi missing (a2enmod proxy_fcgi)'; exit 1; }
apache2ctl -M 2>/dev/null | grep -q rewrite_module || { die 'mod_rewrite missing'; exit 1; }
php8.4 -r 'if(PHP_VERSION_ID<80400)exit(1);foreach(["ctype","fileinfo","gd","iconv","pdo_mysql","redis"] as $m){if(!extension_loaded($m)){fwrite(STDERR,"Missing $m\n");exit(1);}}' || { die 'PHP preflight failed'; exit 1; }
[ "$(redis-cli ping 2>/dev/null)" = PONG ] || { die 'Redis unavailable'; exit 1; }
mysql -NBe 'SELECT 1' >/dev/null || { die 'MariaDB root access unavailable'; exit 1; }
apache2ctl configtest
TMP="$(mktemp -d /tmp/bcdisplay-v3.XXXXXXXX)"
ARCHIVE="display-api-service-$VERSION.tar.gz"
BASE="https://github.com/os2display/display-api-service/releases/download/$VERSION"
wget -q --show-progress -O "$TMP/$ARCHIVE" "$BASE/$ARCHIVE"
wget -q -O "$TMP/checksum.txt" "$BASE/checksum.txt"
EXPECTED="$(awk -v a="$ARCHIVE" '$0 ~ a"$" {print $1;exit}' "$TMP/checksum.txt")"
if [ -z "$EXPECTED" ] && [ "$(grep -cve '^[[:space:]]*$' "$TMP/checksum.txt")" -eq 1 ]; then EXPECTED="$(awk 'NF{print $1;exit}' "$TMP/checksum.txt")"; fi
ACTUAL="$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')"
[[ "$EXPECTED" =~ ^[[:xdigit:]]{64}$ ]] && [ "$EXPECTED" = "$ACTUAL" ] || { die 'SHA256 mismatch'; exit 1; }
tar -tzf "$TMP/$ARCHIVE" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END{exit bad?1:0}' || { die 'Unsafe tar paths'; exit 1; }
mkdir "$TMP/stage"
tar -xzf "$TMP/$ARCHIVE" --no-same-owner -C "$TMP/stage"
[ -s "$TMP/stage/.env" ] || wget -q -O "$TMP/stage/.env" "https://raw.githubusercontent.com/os2display/display-api-service/$VERSION/.env"
for f in .env bin/console vendor/autoload.php public/index.php public/release.json public/client/release.json public/client/online-check/index.html; do [ -s "$TMP/stage/$f" ] || { die "Missing artifact file: $f"; exit 1; }; done
printf 'Domain %s, release %s, path %s\n' "$DOMAIN" "$VERSION" "$APP"
read -r -p 'Create new database, app and Apache vhost? [y/N] ' yes
[[ "$yes" =~ ^[Yy]$ ]] || { echo Cancelled; exit 0; }
DB="$(printf %s "$DOMAIN" | tr '.-' '__' | cut -c1-48)"
USER_DB="bcdisp_$(openssl rand -hex 5)"
PASS_DB="$(openssl rand -hex 24)"
[ -z "$(mysql -NBe "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$DB'")" ] || { die 'Database exists'; exit 1; }
mysql -e "CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci"
mysql -e "CREATE USER '$USER_DB'@'localhost' IDENTIFIED BY '$PASS_DB'; GRANT ALL PRIVILEGES ON \`$DB\`.* TO '$USER_DB'@'localhost'"
mkdir -p "$APP"
cp -a "$TMP/stage/." "$APP/"
mkdir -p "$APP/var" "$APP/public/media" "$APP/config/jwt"
SECRET="$(openssl rand -hex 32)"
JWT="$(openssl rand -hex 32)"
DBVER="$(mysql -NBe 'SELECT VERSION()' | sed 's/-MariaDB.*//')-MariaDB"
cat > "$APP/.env.local" <<EOF
APP_ENV=prod
APP_DEBUG=0
APP_SECRET=$SECRET
DATABASE_URL="mysql://$USER_DB:$PASS_DB@localhost:3306/$DB?serverVersion=$DBVER&charset=utf8mb4"
JWT_PASSPHRASE=$JWT
CORS_ALLOW_ORIGIN='^https://$DOMAIN$'
REDIS_CACHE_DSN=redis://127.0.0.1:6379/0
SESSION_HANDLER_DSN=redis://127.0.0.1:6379/0
REDIS_CACHE_PREFIX=Display_$USER_DB
TRUSTED_PROXIES=127.0.0.1,REMOTE_ADDR
EOF
chmod 0640 "$APP/.env.local"
# The restrictive umask creates ROOT and APP with mode 0700 by default.
# Grant www-data traversal/read access without making the release world-readable.
chown root:www-data "$ROOT"
chown -R root:www-data "$APP"
chmod 0750 "$ROOT" "$APP"
chmod -R g+rX "$APP"
chown -R www-data:www-data "$APP/var" "$APP/public/media" "$APP/config/jwt"
sudo -u www-data test -r "$APP/bin/console" || { die 'www-data cannot read bin/console'; exit 1; }
(
cd "$APP"
sudo -u www-data php8.4 bin/console lexik:jwt:generate-keypair --skip-if-exists --no-interaction
sudo -u www-data php8.4 bin/console about --env=prod
sudo -u www-data php8.4 bin/console doctrine:query:sql 'SELECT 1' --no-interaction
sudo -u www-data php8.4 bin/console app:update --no-interaction
sudo -u www-data php8.4 bin/console cache:clear --env=prod --no-debug
)
cat > "$VHOST" <<EOF
<VirtualHost *:80>
 ServerName $DOMAIN
 DocumentRoot $APP/public
 <FilesMatch "\\.php$">
  SetHandler "proxy:unix:/run/php/php8.4-fpm.sock|fcgi://localhost/"
 </FilesMatch>
 <Directory $APP/public>
  Require all granted
  Options FollowSymLinks
  AllowOverride None
  FallbackResource /index.php
 </Directory>
 RewriteEngine On
 RewriteCond %{REQUEST_URI} !^/client/release\\.json$
 RewriteCond %{REQUEST_URI} !^/client/online-check(?:/|$)
 RewriteRule ^/?client(?:/.*)?$ /index.php [END]
 <Directory $APP/public/client/online-check>
  Require all granted
  Options FollowSymLinks
  DirectoryIndex index.html
  FallbackResource disabled
 </Directory>
 ErrorLog \${APACHE_LOG_DIR}/$DOMAIN-error.log
 CustomLog \${APACHE_LOG_DIR}/$DOMAIN-access.log combined
</VirtualHost>
EOF
apache2ctl configtest
a2ensite "$DOMAIN.conf"
apache2ctl configtest
systemctl restart apache2
for path in /release.json /client/release.json /client/ /client/online-check/ /config/admin /config/client /admin; do
 curl -fsS -H "Host: $DOMAIN" --max-time 15 "http://127.0.0.1$path" -o /dev/null && printf 'OK: %s\n' "$path" || printf 'WARNING: %s\n' "$path" >&2
done
printf 'Installed %s in %s\n' "$VERSION" "$APP"
echo 'Next: verify HTTPS on the reverse proxy, then use app:tenant:add and app:user:add as www-data with php8.4.'