# Current project state

Last updated: 2026-11-07

## Project

Bellcom maintains a native, non-Docker OS2Display installation and upgrade profile.

Repository:

`bellcom/os2display-standard-installation`

## OS2Display 3 fresh installation: verified (2026-11-07)

Production candidate `bdkdisplay.bcdisplay.dk` was installed on `bdk-display01.bellcom.dk` (Debian 13) with OS2Display 3.0.0-rc8. Initial installer issues: it required mod_php instead of FPM (fixed in PR #3), and `umask 077` caused the app root to be inaccessible to `www-data` (fixed in PR #4). The partial deployment was recovered manually; its Symfony initialization, Apache FPM routing, seven HTTP endpoints and external HTTPS routes worked. A tenant and admin login on the production candidate were reported working by the operator.

**Independent clean-install validation:** on a fresh Debian 13 server `test-bdk-display01.bellcom.dk` the host setup (PR #5 switches it to FPM) and `INSTALL_V3.sh test-bdkdisplay.bcdisplay.dk` completed with no manual intervention. PHP 8.4.27 FPM, Redis PONG, MariaDB 11.8.6, JWT generation, DB connectivity, migration `DoctrineMigrations\\Version20260506215847` (1 migration / 77 SQL queries), templates/layouts update, cache clear and Apache vhost were successful. The local probes `/release.json`, `/client/release.json`, `/client/`, `/client/online-check/`, `/config/admin`, `/config/client`, `/admin` all returned HTTP 200; empty Apache error log. External test `https://test-bdkdisplay.bcdisplay.dk/admin` returned HTTP/2 200. A second `INSTALL_V3.sh` invocation correctly refused to overwrite the site.

**Functional validation:** The operator confirmed successful testing of the newly installed test environment, in addition to the automated installation and HTTP checks. The OS2Display 3.0.0-rc8 target is a release candidate, not an automatically discovered latest stable release. This fresh-install test does not establish v2 migration behavior.

## OS2Display 3 upgrade status

A real test migration has been completed on:

`os2display-test.ballerup.dk`

Upgrade path tested:

```text
OS2Display API 2.8.1 -> OS2Display 3.0.0-rc8
```

## Current upgrade implementation

Primary script:

`UPDATE_V3.sh`

The current upgrade approach uses the official production release artifact rather than a source checkout.

## Important findings from the first migration

### PHP 8.4 database driver

The first post-cutover migration attempt failed because PHP 8.4 did not have `pdo_mysql`.

Observed error:

`could not find driver`

The updater must verify `pdo_mysql` and perform a real database query from the staged 3.x application before cutover.

### Redis

The deployment uses a local Redis service and PHP 8.4 Redis support.

Expected Redis check:

```text
PONG
```

### Production artifact `.env`

The tested release artifact did not contain the root `.env` file.

The updater therefore fetches `.env` from the exact same release tag when missing.

### Checksum handling

The upstream checksum file can contain a relative path such as `../assets/...`.

The updater compares the SHA-256 digest itself instead of using the checksum path literally.

### Configuration conversion

Admin/client configuration must be converted from the local 2.x files rather than relying on HTTP access to `/admin/config.json`.

### Apache `/client` collision

`/client` is a Symfony route, but the artifact also contains a physical `public/client` directory.

Without explicit routing, Apache can redirect to `/client/` and then return 403.

The vhost must route application client paths to Symfony while preserving static access to:

- `/client/release.json`
- `/client/online-check/`

### Reverse proxy restrictions

A test-only Nginx `/admin` IP allowlist was removed because it was not used on the other installations and interfered with the 3.x application flow.

Old 2.x admin/client proxy special-cases should not be copied automatically to 3.x.

### Stale Fail2ban deny file

A browser IP was found in the global Nginx `fail2ban-deny.conf` even though Fail2ban showed no active ban.

This is a separate operations issue and not part of the OS2Display 3.x migration itself.

## Verified post-upgrade state on the test installation

- OS2Display: `3.0.0-rc8`
- Doctrine migrations: current = latest, new = 0
- bundled templates updated
- screen layouts updated
- no deprecated feed sources found
- Redis responding
- `/release.json`: working
- `/client/release.json`: working
- `/client/`: working after Apache routing fix
- `/client/online-check/`: working
- `/config/admin`: working
- `/config/client`: working

## Current operational requirements

Before cutover the updater should verify:

- source API version
- no pending 2.x migrations
- PHP >= 8.4
- required PHP extensions
- Redis availability
- staged Symfony boot
- staged database connectivity
- artifact checksum
- valid Apache vhost configuration

## Next work

1. Test `UPDATE_V3.sh` on a second installation with a different existing vhost/configuration.
2. Verify physical screen reconnect behavior on each production candidate before deleting backups.
3. Review custom/external templates before production migration and port them while preserving template IDs where required.
4. Update the default target when a newer supported 3.x release becomes the production choice.
5. Maintain this file after each significant migration finding so a new engineer or AI agent can continue without reconstructing the full chat history.
