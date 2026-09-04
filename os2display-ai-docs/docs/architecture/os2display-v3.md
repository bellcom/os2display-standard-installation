# OS2Display 3 architecture in Bellcom's native deployment

## Purpose

This document describes the OS2Display 3.x architecture relevant to Bellcom's classic Debian/Apache/PHP deployment without Docker.

## Main architectural change from 2.x

In OS2Display 2.x, Bellcom deployed separate components for:

- API
- Admin frontend
- Client frontend
- templates/layouts

In OS2Display 3.x these are delivered together by `display-api-service`.

The application itself serves routes such as:

- `/admin`
- `/client`
- `/config/admin`
- `/config/client`

Separate `display-admin-client` and `display-client` release trees are no longer deployed as independent applications.

## Production release source

Bellcom production deployments use the official OS2Display GitHub release production artifact.

Do not replace this with a bare source Git checkout unless that deployment model is deliberately changed and documented in an ADR.

The production artifact includes the built frontend and PHP vendor dependencies, so Composer and Node/Yarn are not required for the normal production upgrade path.

## PHP

OS2Display 3.x requires PHP >= 8.4.

For Bellcom's MariaDB/MySQL deployment, the PHP 8.4 runtime must at minimum provide:

- `ctype`
- `fileinfo`
- `gd`
- `iconv`
- `pdo_mysql`
- `redis` or `relay`

Typical supporting extensions include:

- `intl`
- `mbstring`
- `xml`
- `opcache`

The PHP binary used for migration commands must be the same major/minor runtime expected by the deployed application.

## Redis

Current Bellcom deployments use a local Redis server, typically reachable at:

`127.0.0.1:6379`

A preflight should verify both:

- Redis responds to `PING`.
- PHP 8.4 has a usable Redis client extension (`redis` or `relay`).

## Persistent installation data

The following must survive an upgrade from 2.x to 3.x:

- `config/jwt`
- `public/media`
- converted production configuration in `.env.local`

Do not regenerate JWT keys during an in-place upgrade unless intentionally re-pairing clients is acceptable.

## Apache routing

The application has a Symfony route for `/client`, but the 3.x artifact also contains a physical `public/client` directory for static files such as:

- `public/client/release.json`
- `public/client/online-check/index.html`
- `public/client/online-check/1pixel.png`

This creates a filesystem/route collision in Apache.

Bellcom resolves it by routing `/client` and ordinary `/client/...` application paths to Symfony, while leaving the static release and online-check paths accessible as files.

The required Apache pattern is documented in `docs/runbooks/upgrade-v2-to-v3.md` and the implementation belongs in `UPDATE_V3.sh`.

## Reverse proxy

Nginx should normally proxy the OS2Display site as one application:

```nginx
location / {
    proxy_pass http://BACKEND:80;
}
```

Old 2.x `/admin` and `/client` proxy special-cases should not be carried forward without an explicit reason.

Access restrictions at the reverse proxy layer must be evaluated carefully because they can interfere with application communication in 3.x.
