# Runbook: upgrade OS2Display 2.8.1 to 3.x

## Scope

This runbook covers Bellcom's native, non-Docker OS2Display deployment.

It is based on the tested migration of `os2display-test.ballerup.dk` from API 2.8.1 to OS2Display 3.0.0-rc8.

Use `UPDATE_V3.sh` as the implementation of this procedure. This document explains the expected sequence and the checks the script must perform.

## 1. Required starting state

Before starting the 3.x upgrade:

- The existing API must be exactly 2.8.1 unless the updater has deliberately been updated for another supported source version.
- All 2.x Doctrine migrations must be applied.
- The existing installation must be functional before migration.
- Database and filesystem locations must be known.

The updater should abort if the 2.x migration status reports pending migrations.

## 2. PHP 8.4 preflight

OS2Display 3.x requires PHP >= 8.4.

Verify the selected PHP 8.4 binary has:

- `ctype`
- `fileinfo`
- `gd`
- `iconv`
- `pdo_mysql`
- `redis` or `relay`

For the Bellcom deployment, `pdo_mysql` is mandatory even if Composer does not list it directly as a platform requirement.

A missing `pdo_mysql` caused the first real cutover attempt to fail with:

`An exception occurred in the driver: could not find driver`

This must be detected before cutover.

Typical Debian/Sury packages include:

```text
php8.4-cli
php8.4-common
php8.4-gd
php8.4-intl
php8.4-mbstring
php8.4-xml
php8.4-mysql
php8.4-redis
php8.4-opcache
```

If Apache uses mod_php, `libapache2-mod-php8.4` must also be installed and enabled.

## 3. Redis preflight

Verify Redis is reachable:

```bash
redis-cli ping
```

Expected result:

```text
PONG
```

Also verify the selected PHP 8.4 runtime has `redis` or `relay` loaded.

## 4. Convert 2.x configuration

Use the upstream conversion command:

```bash
php bin/console app:utils:convert-env-to-3x --skip-config-json
```

Admin and client runtime configuration should be converted from local files:

```text
admin/config.json
client/config.json
```

Do not depend on HTTP retrieval of `/admin/config.json`, because reverse-proxy access rules can block it.

Preserve installation-specific values such as:

- application secret
- database configuration
- JWT configuration
- admin configuration
- client configuration

Write the resulting 3.x runtime configuration to `.env.local`.

## 5. Download and verify the production artifact

Download the exact target release artifact from the official OS2Display GitHub release.

Verify the SHA-256 digest using the matching checksum file.

The upstream checksum file may contain a relative artifact path. Compare the digest value itself rather than relying on the checksum filename path to match the local download path.

## 6. Base `.env`

The tested production artifact did not contain the repository root `.env` file.

If `.env` is missing after extraction, fetch `.env` from the exact same release tag as the artifact.

Do not create an empty `.env`.

Symfony Runtime requires the base environment definition in addition to `.env.local`.

## 7. Preserve persistent data

Before staging validation, copy into the staged 3.x tree:

- existing `config/jwt`
- existing `public/media`
- converted `.env.local`

Do not regenerate JWT keys during the migration.

## 8. Staging validation before cutover

Before any live tree is replaced, run at least:

```bash
php8.4 bin/console about --env=prod
php8.4 bin/console doctrine:query:sql 'SELECT 1'
```

The database query is specifically required to catch PHP/database driver mismatches before cutover.

Do not continue if either command fails.

## 9. Backup

Before cutover, create:

- a database dump
- a complete filesystem backup of the installation

Record their paths in updater output.

Keep them until functional validation is complete.

## 10. Apache vhost migration

Remove old 2.x static frontend blocks for:

```text
public/admin
public/client
```

Keep the general Symfony public directory configuration.

### Required `/client` routing workaround

OS2Display 3.x has a Symfony `/client` route while also shipping a physical `public/client` directory.

Use rules equivalent to:

```apache
# BEGIN OS2Display 3.x client routing
RewriteEngine On
RewriteCond %{REQUEST_URI} !^/client/release\.json$
RewriteCond %{REQUEST_URI} !^/client/online-check(?:/|$)
RewriteRule ^/?client(?:/.*)?$ /index.php [END]

<Directory /var/www/DOMAIN/public_html/public/client/online-check>
   Require all granted
   Options FollowSymLinks
   DirectoryIndex index.html
   FallbackResource disabled
</Directory>
# END OS2Display 3.x client routing
```

Expected behavior:

```text
/client/                  -> Symfony application
/client/foo               -> Symfony application
/client/release.json      -> static file
/client/online-check/     -> static index.html
```

Run:

```bash
apache2ctl configtest
```

before cutover.

Do not continue if the configuration test fails.

## 11. Cutover

The expected cutover pattern is:

```text
public_html -> public_html.v2-TIMESTAMP
staging     -> public_html
```

Do not delete the previous 2.x tree during the migration.

## 12. Database/content migration

After cutover, run with PHP 8.4:

```bash
php8.4 bin/console doctrine:migrations:rollup --no-interaction
php8.4 bin/console app:update --no-interaction
php8.4 bin/console cache:clear --env=prod --no-debug
```

`app:update` is the normal 3.x application update path and updates installed bundled templates and screen layouts in addition to migration work.

## 13. Deprecated feed sources

Report deprecated feed sources using:

```bash
php8.4 bin/console app:feed:remove-deprecated-feed-sources
```

Do not automatically remove them with `--force` unless explicitly requested.

The 2.x feed types known to be removed in 3.x include:

- `SparkleIOFeedType`
- `EventDatabaseApiFeedType`
- `KobaFeedType`

## 14. Apache restart

On mod_php deployments, use a real Apache restart after the PHP/cutover changes rather than relying only on reload.

Always run `apache2ctl configtest` first.

## 15. HTTP validation

Validate locally against Apache and through the public reverse proxy.

At minimum check:

```text
/release.json
/client/release.json
/client/
/client/online-check/
/config/admin
/config/client
/admin
```

A successful `/client/release.json` alone is not sufficient; the actual `/client/` application route must also return successfully.

## 16. Functional validation

Before considering the migration complete, verify:

- admin login
- tenants
- screens
- slides/playlists
- media
- preview
- client rendering
- an existing physical screen reconnects without requiring a new pairing

The existing-screen reconnect is an important validation that the old JWT keys were preserved correctly.

## 17. Keep rollback material

Keep until validation is complete:

- database dump
- filesystem backup
- `public_html.v2-TIMESTAMP`

Database rollback after a 3.x migration must be treated carefully; do not blindly swap only the application tree after the database schema has changed.

## 18. Reverse proxy notes

Do not carry forward old 2.x `/admin` or `/client` Nginx locations unless they are still deliberately required.

The default 3.x model is a single proxy location for the entire application.

A separate operational issue discovered during testing was a stale entry in:

`/etc/nginx/snippets/fail2ban-deny.conf`

An IP could remain as `deny IP;` even though Fail2ban no longer considered it banned. This is not an OS2Display 3.x migration issue, but it can produce misleading Nginx 403 responses and should be maintained separately.
