# ADR 0002: Use official production release artifacts for OS2Display 3.x

Status: Accepted

Date: 2026-09-04

## Context

OS2Display 2.x Bellcom installations used a Git checkout for the API plus separately deployed frontend releases.

OS2Display 3.x combines API, Admin, Client and bundled frontend assets into `display-api-service`.

The official release provides a production artifact containing built frontend assets and PHP vendor dependencies.

## Decision

Bellcom production upgrades to OS2Display 3.x will use the official GitHub production release artifact.

A normal production upgrade will not deploy a bare source Git checkout and will not rebuild the frontend locally.

## Consequences

- Composer and Node/Yarn are not required for the standard production deployment step.
- The artifact checksum must be verified before deployment.
- Runtime configuration and persistent data must be injected into the staged artifact.
- If an artifact omits a required repository file such as the root `.env`, that file must be fetched from the exact same release tag.
- Future upgrade logic should continue to use `app:update` for the deployed 3.x application.
