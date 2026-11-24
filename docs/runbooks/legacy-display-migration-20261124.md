# Legacy OS2Display migration, 2026-11-24

The production migration from API 2.5.2+ (develop) via 2.8.1 to stable 3.0.0 succeeded on Debian 13 with PHP 8.4 FPM. All seven local and external HTTPS endpoints returned 200. Physical screen reconnect without re-pairing remains to be confirmed.

## Host preparation

The shared scripts/lib/php-packages.sh helper installs missing versioned PHP packages after APT simulation and explicit approval, preserves the existing CLI PHP executable, and creates the Bellcom FPM INI defaults if absent. Existing custom configuration is not overwritten. Debian package sources must already provide PHP 8.4 (use the approved host preparation on fresh hosts). Package installation can affect services; use a maintenance window and a verified backup/snapshot.

## Legacy layout

The V2 updater resolves the actual application path for ownership changes. The V3 migration and release updater recognize public_html -> public, preserving the live path during cutover. Other symlinks are refused. The release updater requires a newer 3.x version, not a downgrade.

## Remaining manual preparation

The legacy mod_php vhost must still be reviewed and converted to PHP 8.4 FPM, preserving site-specific settings and frontend restrictions. Use a dedicated pool and size it for available RAM. Check Apache config and HTTP before proceeding. Do not deactivate TLS vhosts until the reverse proxy path has been verified. A local loopback hosts mapping requires an external HTTPS test. Review local custom code before migration. Preserve database and filesystem backups until functional validation is complete.

These repository changes have not been tested end-to-end; the successful production migration used the preceding scripts plus manual host preparation.
