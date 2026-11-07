# OS2Display — Bellcom standard installation (native, without Docker)

This repository contains Bellcom's Debian/Apache/MariaDB/Redis installation tools and the migration from OS2Display 2.8.1 to OS2Display 3.x.

**Important:** `scripts/setup.sh` prepares a server; it does **not** install the OS2Display application. For a fresh OS2Display 3 installation, use `INSTALL_V3.sh`. `INSTALL.sh` remains a legacy 2.x installer.

## Choose the right procedure

| Starting point | Procedure |
| --- | --- |
| Existing, working OS2Display API **2.8.1** | Use [`UPDATE_V3.sh`](UPDATE_V3.sh) and the [migration runbook](docs/runbooks/upgrade-v2-to-v3.md). |
| Existing OS2Display version older than 2.8.1 | First upgrade 2.x to exactly 2.8.1, and finish all 2.x Doctrine migrations. |
| Completely new host / no existing OS2Display | Run `scripts/setup.sh` to prepare the host, then use [`INSTALL_V3.sh`](INSTALL_V3.sh) after reviewing its preflight and limitations. Never run legacy `INSTALL.sh` for 3.x. |

**Existing installations:** Do not run `setup.sh` or `INSTALL.sh` before `UPDATE_V3.sh` on a live installation. Check requirements and backups using the runbook.

## Host preparation (new Debian host only)

Test target for this updated setup: **Debian 12 or 13** with root/sudo privileges, DNS for the eventual application domain, and network access to Debian/Sury, GitHub and OS2Display releases. Ubuntu support is not covered by this revised setup script.

The script installs Apache, MariaDB, Redis and PHP **8.4** with `pdo_mysql` and `redis` support. It clones **this Bellcom repository** into `/var/www/display`, does **not** delete older PHP installations or databases, and does **not** change the system-wide `php` alternative. It may install a Sury PHP package repository and restart Apache; review the script before running it. It uses PHP-FPM 8.4 (not mod_php).

```bash
sudo wget -O /var/setup.sh https://raw.githubusercontent.com/bellcom/os2display-standard-installation/main/scripts/setup.sh &&
sudo bash -n /var/setup.sh &&
sudo bash /var/setup.sh
```

**Checks:**

```bash
php8.4 -v
php8.4 -m | grep -Ei '^(gd|pdo_mysql|redis|mbstring|intl)$'
redis-cli ping
sudo apache2ctl configtest
systemctl is-active php8.4-fpm
git -C /var/www/display remote -v
```

Expected Redis result: `PONG`. The Git remote must be `https://github.com/bellcom/os2display-standard-installation.git`.

## Fresh OS2Display 3 installation (new domain only)

This is a native installer for Debian with Apache + PHP-FPM 8.4, MariaDB, Redis and a valid DNS name. The default target is **3.0.0-rc8**; set `OS2DISPLAY_VERSION` to a separately verified published release tag to use another version. It does not select the latest release automatically.

The installer refuses to overwrite an existing site or Apache vhost. It downloads the official production artifact and matching checksum, creates a new MariaDB database and user, writes production secrets to `.env.local`, generates JWT keys, invokes `app:update` (database migrations, bundled templates, layouts), and configures a basic HTTP Apache vhost. The installer is not an updater and must **never** be used for an existing v2/v3 site.

```bash
cd /var/www/display
sudo bash -n ./INSTALL_V3.sh
sudo bash ./INSTALL_V3.sh display.example.dk
```

If you choose a different release, verify that its archive, checksum, required environment variables and CLI commands remain compatible first.

After installation, configure HTTPS at Apache or your reverse proxy, and create a tenant and an administrator:

```bash
cd /var/www/display.example.dk/public_html
sudo -u www-data php8.4 bin/console app:tenant:add
sudo -u www-data php8.4 bin/console app:user:add
```

Verify: `php8.4 -m`, `redis-cli ping`, `apache2ctl configtest`, `php8.4 bin/console doctrine:migrations:status --no-interaction` (as www-data), and HTTP routes `/admin`, `/client/`, `/config/admin`, `/config/client`. The initial Apache vhost listens on HTTP port 80 only; TLS is a separate step. If the installer stops after creating the database, inspect and clean up the partial installation manually before retrying. **Verified 2026-11-07:** the complete clean-host installation of OS2Display `3.0.0-rc8` on Debian 13 passed on `test-bdk-display01.bellcom.dk` using PHP-FPM 8.4. All seven local HTTP endpoints returned 200, and `/admin` through the external HTTPS proxy returned 200. Tenant creation, admin login and real screen/content workflows were not part of that clean-install verification.

## Clean-install verification (2026-11-07)

**Host:** `test-bdk-display01.bellcom.dk` (Debian 13 trixie, fresh host). **Public domain:** `test-bdkdisplay.bcdisplay.dk`. TLS is terminated on a separate Nginx reverse proxy; the app's Apache vhost uses port 80 and PHP-FPM 8.4.

1. `scripts/setup.sh` provisioned Apache, PHP 8.4.27 / PHP-FPM, MariaDB 11.8.6, Redis, and the Bellcom repository. Checks: FPM active with `/run/php/php8.4-fpm.sock`, `proxy_fcgi` and `rewrite` loaded, `redis-cli ping` => `PONG`, `apache2ctl configtest` => `Syntax OK`.
2. `INSTALL_V3.sh test-bdkdisplay.bcdisplay.dk` completed **without manual repairs**: verified release archive/checksum; generated JWT keys; connected to database (`SELECT 1`); ran Doctrine migration `DoctrineMigrations\\Version20260506215847` (1 migration, 77 SQL queries); updated templates/layouts; cleared Symfony prod cache; created and activated the Apache vhost with PHP-FPM.
3. All local endpoint probes returned **HTTP 200**: `/release.json`, `/client/release.json`, `/client/`, `/client/online-check/`, `/config/admin`, `/config/client`, `/admin`. Apache error log was empty during the probe.
4. External `https://test-bdkdisplay.bcdisplay.dk/admin` returned **HTTP/2 200** through Nginx.
5. Running the installer a second time correctly refused an existing site/vhost (`ERROR: Site or vhost already exists`). **Do not rerun it on an installed site.**

**Prior production-host finding:** the first installation at `bdkdisplay.bcdisplay.dk` stopped at `Could not open input file: bin/console`: `umask 077` produced non-traversable site directories for `www-data`. That partial deployment was recovered by adjusting permissions and running Symfony setup commands, then manually creating its Apache FPM vhost. The new installer includes the permanent permission fix (PR #4). Host setup previously installed `mod_php8.4`, while the app installer expected FPM; setup now provisions FPM (PR #5).

**Not yet verified as part of the clean-install test:** tenant/admin creation and login on the test host, interactive screen/layout/media operations, physical display pairing, and any production traffic. HTTP 200 confirms route availability, not application authorization or end-user workflows.

## Upgrade an existing OS2Display 2.8.1 installation to 3.x

Read the [upgrade runbook](docs/runbooks/upgrade-v2-to-v3.md) completely. Back up and verify the existing installation, ensure PHP 8.4 and extensions are available, verify Redis, and check that no 2.x migrations are pending.

The script defaults to **3.0.0-rc8** (the version tested in the runbook); it does **not** dynamically select the newest stable 3.x release. Confirm your intended target version and the availability of its official release artifact before running it.

```bash
cd /var/www/display
sudo bash ./UPDATE_V3.sh your.domain.dk
```

To explicitly select a reviewed newer release:

```bash
cd /var/www/display
sudo OS2DISPLAY_VERSION=YOUR_VERIFIED_3X_TAG bash ./UPDATE_V3.sh your.domain.dk
```

The updater requires the current API Git checkout to be at tag `2.8.1`, creates backups, converts local admin/client configuration, verifies the production artifact SHA-256, preserves JWT keys and media, stages and validates the application, adjusts Apache routing, and performs 3.x database/content migrations. **The database conversion is not safely rolled back by swapping only the application directory.** Retain the database dump and filesystem backups until functional checks succeed.

Afterward check `/admin`, `/client/`, `/client/online-check/`, `/config/admin`, screens, media, templates and reconnecting physical screens.

## Legacy 2.x installer

[`INSTALL.sh`](INSTALL.sh) is maintained for legacy 2.x deployments only. It may drop an existing database and re-create the installation. Do not use it to migrate an existing site or to install a new 3.x site.

## Documentation

- [Project instructions](AGENTS.md)
- [OS2Display 3 architecture](docs/architecture/os2display-v3.md)
- [2.8.1 to 3.x upgrade runbook](docs/runbooks/upgrade-v2-to-v3.md)
- [Current state](docs/ai/CURRENT_STATE.md)
- [Architecture decisions](docs/decisions/)
