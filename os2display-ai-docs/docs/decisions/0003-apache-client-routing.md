# ADR 0003: Explicitly route OS2Display 3.x `/client` through Symfony in Apache

Status: Accepted

Date: 2026-09-04

## Context

OS2Display 3.x defines `/client` as an application route while the production artifact also contains a physical `public/client` directory for static runtime files.

With Bellcom's normal Apache configuration, the physical directory takes precedence over the Symfony fallback. This caused:

- `/client` to redirect to `/client/`
- `/client/` to return Apache 403
- `/client/online-check/` to fail because the inherited `DirectoryIndex` expected `index.php`

## Decision

Bellcom's 3.x Apache vhost explicitly routes `/client` application paths to `/index.php`, while excluding the required static paths.

The online-check directory explicitly uses `index.html` and disables the Symfony fallback.

## Consequences

Expected routing is:

```text
/client/                  -> Symfony application
/client/foo               -> Symfony application
/client/release.json      -> static file
/client/online-check/     -> static index.html
```

The vhost migration must also remove the old OS2Display 2.x static `public/admin` and `public/client` directory blocks.

This behavior is implemented by `UPDATE_V3.sh` and documented in the upgrade runbook.
