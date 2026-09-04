# Agent instructions

This repository contains Bellcom's native, non-Docker installation and upgrade tooling for OS2Display.

Before changing OS2Display 3.x installation or upgrade logic, read:

- `docs/architecture/os2display-v3.md`
- `docs/runbooks/upgrade-v2-to-v3.md`
- `docs/ai/CURRENT_STATE.md`
- `docs/decisions/`

## Operational rules

- Existing 2.x installations must be upgraded to API 2.8.1 before the 3.x migration.
- OS2Display 3.x requires PHP >= 8.4.
- Production deployments use the official GitHub release artifact, not a source Git checkout.
- Preserve `config/jwt` and `public/media` during upgrades.
- Keep runtime secrets out of Git: never commit `.env`, `.env.local`, `db.txt`, passwords, certificates or private keys.
- Apache has special routing requirements for `/client` in OS2Display 3.x because the route overlaps a physical `public/client` directory.
- Do not automatically delete deprecated feed sources.
- Keep database and file backups, plus the previous 2.x tree, until functional validation is complete.
- Do not assume Docker or Docker Compose is available.

## Shell safety for operational instructions

For commands intended to be pasted directly into an active shell:

- Do not use `set -e`, `set -u`, `set -o pipefail` or `set -euo pipefail`.
- Do not use `exit`, `logout` or `exec`.
- Do not reboot or shut down a server unless explicitly requested.
- If a step fails, report the failure clearly and do not continue with dependent steps.

Strict mode is acceptable inside a saved script file.

## Change discipline

When changing upgrade logic:

1. Prefer preflight validation before any live cutover.
2. Validate Apache configuration before reloading/restarting Apache.
3. Verify the database connection using the PHP binary intended for OS2Display 3.x before cutover.
4. Preserve existing installation-specific configuration instead of replacing it with defaults.
5. Update `docs/ai/CURRENT_STATE.md` when the tested state, target release, known pitfalls or next steps change.
6. Add or update an ADR when a durable architectural or operational decision changes.
