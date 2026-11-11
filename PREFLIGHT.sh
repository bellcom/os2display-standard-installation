#!/usr/bin/env bash
# Bellcom OS2Display read-only preflight for existing Debian installations.
# Usage: bash PREFLIGHT.sh test-os2display.naestved.dk
# No installation, database changes, repo changes, or root requirement.
set -o pipefail
DOMAIN="${1:-}"
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ || "$DOMAIN" != *.* ]]; then
  printf 'FEJL: Angiv domæne, fx bash PREFLIGHT.sh test-os2display.naestved.dk\n' >&2
  exit 2
fi
ROOT="/var/www/$DOMAIN"
APP=""
for path in "$ROOT/public_html" "$ROOT/public"; do
  if [ -f "$path/bin/console" ]; then APP="$path"; break; fi
done
printf '=== BELLCOM OS2DISPLAY PREFLIGHT ===\nDomæne: %s\nServer: %s\n' "$DOMAIN" "$(hostname -f 2>/dev/null || hostname)"
if [ -r /etc/os-release ]; then . /etc/os-release; printf 'OS: %s\n' "$PRETTY_NAME"; fi
printf '\n=== INSTALLATION ===\n'
if [ -z "$APP" ]; then printf 'FEJL: Symfony installation ikke fundet i %s/{public_html,public}\n' "$ROOT"; exit 1; fi
printf 'App: %s\n' "$APP"
if [ -e "$APP/.os2display-version" ]; then printf 'V3 release: %s\n' "$(head -1 "$APP/.os2display-version")"; fi
if [ -d "$APP/.git" ] && command -v git >/dev/null; then
  printf 'Git: '
  git -c safe.directory="$APP" -C "$APP" describe --tags --always 2>/dev/null || printf 'Ukendt\n'
  printf 'Branch: '
  git -c safe.directory="$APP" -C "$APP" branch --show-current 2>/dev/null || true
  printf 'Lokale ændringer (antal): '
  git -c safe.directory="$APP" -C "$APP" status --porcelain 2>/dev/null | wc -l
fi
printf '\n=== PHP-MODULER ===\n'
for v in 8.3 8.4; do
  if command -v "php$v" >/dev/null 2>&1; then
    printf 'PHP %s: ' "$v"
    "php$v" -r 'echo PHP_VERSION, PHP_EOL;'
    "php$v" -r '
      foreach (["ctype","fileinfo","gd","iconv","pdo_mysql","redis","imagick","intl","mbstring","zip"] as $x) {
        printf("  %-12s %s\\n", $x, extension_loaded($x) ? "OK" : "MANGLER");
      }'
  else printf 'PHP %s: MANGLER\n' "$v"; fi
done
printf '\n=== APACHE ===\n'
if [ -x /usr/sbin/apache2ctl ]; then
  /usr/sbin/apache2ctl configtest 2>&1 || true
  /usr/sbin/apache2ctl -S 2>&1 | grep -F "$DOMAIN" || true
else printf 'Apachectl ikke tilgængelig\n'; fi
for p in /etc/apache2/mods-enabled/php*.load; do
  if [ -e "$p" ]; then printf 'Aktivt mod_php: %s\n' "$(basename "$(readlink -f "$p")")"; fi
done
if command -v systemctl >/dev/null; then
  for srv in apache2 mariadb redis-server php8.4-fpm; do printf '%-16s %s\n' "$srv" "$(systemctl is-active "$srv" 2>/dev/null || true)"; done
fi
printf '\n=== PHP WEB-KONFIGURATION ===\n'
for sapi in apache2 fpm; do
  ini="/etc/php/8.4/$sapi/php.ini"
  scan="/etc/php/8.4/$sapi/conf.d"
  [ -f "$ini" ] && [ -d "$scan" ] || continue
  printf '%s:\n' "$sapi"
  if command -v php8.4 >/dev/null; then
    PHP_INI_SCAN_DIR="$scan" php8.4 -c "$ini" -r '
      foreach (["memory_limit"=>1024,"post_max_size"=>200,"upload_max_filesize"=>200] as $k=>$min) {
        $v=ini_get($k);$u=strtoupper(substr($v,-1));$n=(float)$v;
        $mb=($v==="-1")?INF:($u==="G"?$n*1024:($u==="M"?$n:($u==="K"?$n/1024:$n/1048576)));
        printf("  %s=%s (Bellcom min %dM): %s\\n",$k,$v,$min,$mb>=$min?"OK":"FOR LAV");
      }'
  fi
done
printf '\n=== CACHE / DATABASEMIGRATIONER ===\n'
if [ -e "$APP/.env.local.php" ]; then printf 'OBS: .env.local.php findes og kan tilsidesætte .env.local\n'; fi
if [ -f "$APP/vendor/autoload.php" ]; then
  phpbin=""
  for v in 8.3 8.4; do if command -v "php$v" >/dev/null; then phpbin="php$v"; break; fi; done
  if [ -n "$phpbin" ]; then
    ( cd "$APP" && "$phpbin" bin/console doctrine:migrations:status --no-interaction 2>&1 ) || printf 'ADVARSEL: migrationsstatus kunne ikke læses uden ændringer\n'
  fi
else printf 'ADVARSEL: vendor/autoload.php mangler\n'; fi
printf '\n=== LAGER / BACKUP ===\n'
df -h "$ROOT" 2>/dev/null || true
if [ -d /var/www/backup ]; then ls -ld /var/www/backup; else printf 'ADVARSEL: /var/www/backup mangler\n'; fi
printf '\n=== OPGRADERINGSVEJ ===\n'
if [ -f "$APP/.os2display-version" ]; then
  printf 'Eksisterende V3: brug UPDATE_V3_RELEASE.sh efter kontrol af release-version\n'
else
  printf 'V2: kontrollér tag og migrationer; opgrader først til 2.8.1, derefter UPDATE_V3.sh til 3.0.0\n'
fi
printf 'OBS: HTTPS kontrolleres på central reverse proxy, backend HTTP lokalt.\n'
