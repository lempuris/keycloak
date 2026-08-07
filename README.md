# Keycloak PoC

A runnable Keycloak environment for familiarisation, built to mirror the target
architecture in [`../design.md`](../design.md) rather than a generic tutorial setup.

`design.md` is the source of truth; [`../ROADMAP.md`](../ROADMAP.md) sequences the work.
**Currently implemented: Phase 0, Phase 1, and the core of Phase 2.**

---

## Prerequisites

Docker Desktop (Linux containers). Nothing else — no local Java, Node or Maven is
needed until the backend/frontend phases.

## Quick start

```powershell
.\infrastructure\scripts\poc.ps1 up
.\infrastructure\scripts\smoke-test.ps1
```

The first `up` creates `.env` from `.env.example` and pulls ~600 MB of images.
Startup takes about a minute; the script waits for the health check.

| Endpoint | URL |
|---|---|
| Admin console | http://localhost:8080/admin |
| Account console | http://localhost:8080/realms/guarantee-gateway/account |
| Discovery document | http://localhost:8080/realms/guarantee-gateway/.well-known/openid-configuration |
| Health / metrics | http://localhost:9000/health/ready · http://localhost:9000/metrics |
| Mailpit inbox | http://localhost:8025 |

Credentials live in `.env` (git-ignored). Defaults: admin `admin` / `local-dev-only-change-me`;
seeded users `thabo.mokoena@example.com` (facility-holder) and
`lerato.dlamini@example.com` (broker), both `PocDemo!2026x`.

> The admin console runs on the master realm over plain HTTP. That is a local-only
> concession — Phase 7 moves it behind TLS on a separate hostname.

## Commands

```powershell
.\infrastructure\scripts\poc.ps1 up                # start, wait for healthy
.\infrastructure\scripts\poc.ps1 status            # container state + endpoints
.\infrastructure\scripts\poc.ps1 logs keycloak     # follow logs
.\infrastructure\scripts\poc.ps1 down              # stop, keep the database
.\infrastructure\scripts\poc.ps1 reset             # destroy the volume, re-import realm
.\infrastructure\scripts\poc.ps1 export-realm      # snapshot the live realm for diffing
```

## Tests

Every check is a real HTTP request against the running stack, not a read-back of
the config we wrote.

```powershell
.\infrastructure\scripts\smoke-test.ps1                 # 29 checks
.\infrastructure\scripts\smoke-test.ps1 -TestLockout    # + 3 lockout checks
.\infrastructure\scripts\test-session-persistence.ps1 -FullRestart
```

`smoke-test.ps1` drives a complete Authorization Code + PKCE login by parsing the
login form and posting credentials, then decodes the resulting JWT and asserts the
role claim. `test-session-persistence.ps1` logs in, recreates the Keycloak
container, and proves the SSO session survives with the same session id.

Shared helpers live in `infrastructure/scripts/_common.ps1`; later phases reuse them.

## What is configured, and why

Everything below comes from `design.md` — the realm is not stock defaults.

| Setting | Value | Source |
|---|---|---|
| Access token lifetime | 5 min | §5 — bounds exposure after deactivation |
| SSO idle / max | 30 min / 10 h | §5 |
| Refresh token rotation | on, no reuse | §5 |
| Self-registration | disabled | §5 — users come from the Marshall feed |
| Remember me | disabled | §5 |
| Brute force | permanent lockout, 3 failures | §6 |
| Password policy | 12 chars, mixed case, digit, special, history 3 | §2 |
| Client `guarantee-gateway-za` | public, Auth Code + PKCE S256, no implicit, no direct grants | §3 |
| Tokens | JWT RS256, realm-managed keys | §1, §7 |
| SMTP | Mailpit, standing in for M365 | §2 |
| Events | login + admin events on, `jboss-logging` | §2 — audit via logs, no listener SPI |

The client has `fullScopeAllowed: false`, so realm roles reach the access token
only through the explicit `scopeMappings` entry. That is deliberate: it is the
practice we want in production, and the smoke test asserts the claim still arrives.

## Layout

```text
keycloak-poc/
├── infrastructure/
│   ├── compose/docker-compose.yml   # all image tags pinned here, only here
│   └── scripts/                     # lifecycle + test scripts
├── keycloak/
│   ├── realms/                      # realm config as code (imported on first start)
│   ├── extensions/                  # (Phase 4) pinned community email-OTP JAR
│   └── themes/                      # (Phase 4) login theme
├── backend/                         # (Phase 3) Spring Boot resource server
├── frontend/                        # (Phase 3) Angular SPA
├── marshall-mock/                   # (Phase 5) provisioning mock
└── docs/                            # per-phase findings
```

## Realm config as code

`keycloak/realms/guarantee-gateway-realm.json` is imported by `--import-realm` on
first start, with Keycloak's `IGNORE_EXISTING` strategy: **once the realm exists,
editing the JSON and restarting changes nothing.** To pick up edits, run
`poc.ps1 reset` (destroys the volume) and `poc.ps1 up`.

That limitation is why ROADMAP Phase 2 calls for keycloak-config-cli or Terraform —
tooling that applies changes idempotently to a live realm. Choosing between them,
and recording the rationale, is still open. See `docs/phase-01-02-findings.md`.

## Not yet done

Phase 2 is only partially complete, and Phases 3–8 are untouched:

- **No idempotent realm-apply tooling** and no config-cli vs Terraform decision.
- **No email OTP.** The browser flow is currently stock username+password only;
  the second factor from `design.md` §5 is Phase 4, and depends on evaluating a
  community extension.
- **No login theme**, no backend, no frontend, no Marshall mock.
- **Single node.** The JDBC_PING clustering and cross-replica lockout spike —
  the highest-value item for the Azure build — is Phase 6.
