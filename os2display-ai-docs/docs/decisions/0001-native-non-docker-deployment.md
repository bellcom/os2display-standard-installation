# ADR 0001: Deploy OS2Display without Docker

Status: Accepted

Date: 2026-09-04

## Context

Bellcom operates OS2Display on traditional Debian servers using system-managed Apache, PHP, MariaDB and Redis services.

Upstream OS2Display documentation and tooling also include Docker-oriented deployment models, but the Bellcom hosting environment is already built around native services and operational tooling.

## Decision

OS2Display will continue to be deployed without Docker for this repository's supported installation profile.

The deployment model is:

- Apache as web server
- PHP installed as system packages
- MariaDB/MySQL as system service
- Redis as system service
- application files under `/var/www/<domain>`

## Consequences

- Upgrade scripts must not assume Docker Compose is available.
- PHP extensions must be validated explicitly on the host.
- Apache vhost migration is part of the upgrade procedure.
- Service restarts and configuration tests are managed through the operating system.
- Upstream Docker examples may be useful as architecture references but are not directly executable deployment instructions for this repository.
