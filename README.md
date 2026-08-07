# Keycloak PoC

A runnable Keycloak environment built to mirror Credeq's target architecture
rather than a generic tutorial setup: Keycloak + PostgreSQL + a Spring Boot
resource server + an Angular SPA, with the realm applied as code.

`design.md` is the source of truth and `ROADMAP.md` sequences the work. Both live
in the internal docs folder alongside this repo, not inside it — section
references below (`§5`, `§7`) point there.

**State: Phases 0–4 complete and verified. Phase 5 (Marshall mock) is a sketch.**
See [Status](#status) for what that means in practice, including one design
requirement the PoC proved cannot be met without a custom SPI.

---

## Prerequisites

Docker Desktop (Linux containers). Nothing else — the backend and frontend build
inside containers, so no local Java, Node or Maven is required.

## Quick start

```powershell
.\infrastructure\scripts\poc.ps1 up
.\infrastructure\scripts\smoke-test.ps1
```

The first `up` creates `.env` from `.env.example` and pulls ~600 MB of images.
One `up` starts the whole stack: Postgres, Keycloak, Mailpit, the realm-config
job, the API and the SPA.

| Endpoint | URL |
|---|---|
| SPA (Angular) | http://localhost:4200 |
| API (Spring Boot) | http://localhost:8081 |
| Admin console | http://localhost:8080/admin |
| Account console | http://localhost:8080/realms/guarantee-gateway/account |
| Discovery document | http://localhost:8080/realms/guarantee-gateway/.well-known/openid-configuration |
| Health / metrics | http://localhost:9000/health/ready · http://localhost:9000/metrics |
| Mailpit inbox | http://localhost:8025 |

Credentials live in `.env` (git-ignored). Defaults: admin `admin` /
`local-dev-only-change-me`; seeded users `thabo.mokoena@example.com`
(facility-holder) and `lerato.dlamini@example.com` (broker), both `PocDemo!2026x`.

Logging in requires the emailed OTP — **read it from the Mailpit inbox at
http://localhost:8025**. No mail leaves the machine.

> The admin console runs on the master realm over plain HTTP. That is a local-only
> concession — Phase 7 moves it behind TLS on a separate hostname.

## Commands

```powershell
.\infrastructure\scripts\poc.ps1 up                # start, wait for healthy
.\infrastructure\scripts\poc.ps1 status            # container state + endpoints
.\infrastructure\scripts\poc.ps1 logs keycloak     # follow logs
.\infrastructure\scripts\poc.ps1 apply-realm       # re-apply realm config to the live realm
.\infrastructure\scripts\poc.ps1 export-realm      # snapshot the live realm for diffing
.\infrastructure\scripts\poc.ps1 restart-keycloak  # recreate just Keycloak
.\infrastructure\scripts\poc.ps1 down              # stop, keep the database
.\infrastructure\scripts\poc.ps1 reset             # destroy the volume, re-apply realm
```

## Tests

Every check is a real HTTP request against the running stack, not a read-back of
the config we wrote. The login tests drive the actual browser flow — parsing the
login form, posting credentials, and reading the OTP out of Mailpit.

```powershell
.\infrastructure\scripts\smoke-test.ps1                       # 29 checks (32 with -TestLockout)
.\infrastructure\scripts\test-api.ps1                         # 15 — SPA -> API, role enforcement
.\infrastructure\scripts\test-session-persistence.ps1         # 6  — sessions survive restart
.\infrastructure\scripts\test-otp-flow.ps1                    # 28 — 27 pass, 1 deliberately red
```

`test-otp-flow.ps1` asserts that failed OTP attempts feed the brute-force
lockout, as `design.md` §5 requires. **That assertion fails, and is left failing
on purpose** — see Finding 3 below. Closing it needs a decision, not a code
change.

Shared helpers live in `infrastructure/scripts/_common.ps1`.

## Status

| Phase | State |
|---|---|
| 0 — Project setup | Done |
| 1 — Infrastructure | Done. Keycloak 26.7.1, PostgreSQL 17.10, Mailpit 1.30.6; health/metrics on `:9000`; persistent sessions proven across container recreation |
| 2 — Core realm as code | Done. Applied by keycloak-config-cli 6.5.1, idempotent (2nd run = zero changes) |
| 3 — App integration | Done. Spring Boot 3.5.3 API + Angular 22 SPA, 200/403 verified in scripts and in a browser |
| 4 — Email OTP flow | Done, **1 requirement unmet** (Finding 3) |
| 5 — Marshall mock | **Sketch only.** `src/keycloak-admin.js` exists; no `server.js`, no Dockerfile, no compose entry, untested |
| 6 — Clustering (JDBC_PING) | Not started. Highest value for the Azure build |
| 7–8 — TLS/proxy, key rotation, pipeline, cutover | Not started |

Also not built: the reset-credentials flow with OTP re-verification, and a
custom login theme.

### Findings that change the design

The point of the PoC is what it disproved. Full write-ups in `docs/`.

1. **`--import-realm` is create-only** (`IGNORE_EXISTING`), so realm edits never
   reached an existing realm. Replaced with keycloak-config-cli.
   → `docs/decision-realm-config-tooling.md`
2. **Keycloak 26.7.1 has no built-in email OTP**, confirmed against the running
   server. Only TOTP/HOTP and recovery codes. Email OTP needs a community
   extension, or TOTP sign-off.
3. **Failed OTPs do not feed the brute-force counter.** Three wrong OTPs leave
   `numFailures=0` and the account enabled. An attacker holding a valid password
   gets unmetered guesses at the 6-digit code for its full 5-minute life. Not
   fixable without writing an authenticator, which the roadmap constraints
   forbid. **Materially strengthens the TOTP case.**
   → `docs/decision-email-otp-extension.md`
4. **`design.md` §6 is wrong twice.** Keycloak sends *no* lockout notification
   email, and lockout is not "3 failures": two failures under one second trip
   `quickLoginCheckMilliSeconds` and permanently disable the account at 2. A user
   who double-submits gets locked out.
5. **config-cli lags Keycloak** — 6.5.1 targets KC 26.1.0 while we run 26.7.1.
   Works, but gates the "bump the image tag" upgrade path.
6. **The authenticator SPI is internal** (`KC-SERVICES0047` at startup) and can
   change without notice. Pre-upgrade UAT must include a full OTP login, and
   upgrades block until the extension ships a matching build.
7. **Internal vs external issuer URL**: the API fetches JWKS at
   `http://keycloak:8080` but validates `iss` as `http://localhost:8080`, so it
   builds a `JwtDecoder` by hand rather than using `issuer-uri`. Exactly what app
   teams will hit at IS4 cutover.

## What is configured, and why

Everything below comes from `design.md` — the realm is not stock defaults.

| Setting | Value | Source |
|---|---|---|
| Access token lifetime | 5 min | §5 — bounds exposure after deactivation |
| SSO idle / max | 30 min / 10 h | §5 |
| Refresh token rotation | on, no reuse | §5 |
| Self-registration | disabled | §5 — users come from the Marshall feed |
| Remember me | disabled | §5 |
| Brute force | permanent lockout, 3 failures | §6 (but see Finding 4) |
| Password policy | 12 chars, mixed case, digit, special, history 3 | §2 |
| Browser flow | Cookie ‖ (Username Password → Email OTP) | §5 |
| Client `guarantee-gateway-za` | public, Auth Code + PKCE S256, no implicit, no direct grants | §3 |
| Tokens | JWT RS256, realm-managed keys | §1, §7 |
| SMTP | Mailpit, standing in for M365 | §2 |
| Events | login + admin events on, `jboss-logging` | §2 — audit via logs, no listener SPI |

The client has `fullScopeAllowed: false`, so realm roles reach the access token
only through the explicit `scopeMappings` entry. That is deliberate — it is the
practice we want in production, and the smoke test asserts the claim still arrives.

**Authorization split** (§4): Keycloak issues identity and a coarse realm role
(`facility-holder` / `broker`). Facility linkage is *not* a token claim — the API
resolves it server-side from the token's identity, and `test-api.ps1` fails if
any business claim appears in the JWT. In this PoC the Marshall lookup is an
in-process stand-in (`backend/.../facility/FacilityDirectory.java`), not a
network call.

## Realm config as code

`keycloak/realms/guarantee-gateway.json` is applied by the `realm-config` service
(keycloak-config-cli) on every `up`, idempotently — editing the JSON and
re-running `poc.ps1 apply-realm` reaches a realm that already exists, which
`--import-realm` could never do.

Secrets are referenced as `$(env:NAME)` rather than hardcoded — the local
stand-in for Key Vault secret references. `IMPORT_MANAGED_USER=no-delete` is
mandatory: `full` would delete users created by the Marshall provisioning feed,
and users are not configuration.

## Layout

```text
keycloak-poc/
├── infrastructure/
│   ├── compose/docker-compose.yml   # all image tags pinned here, only here
│   └── scripts/                     # lifecycle + test scripts
├── keycloak/
│   ├── realms/                      # realm config as code, applied by config-cli
│   ├── extensions/                  # pinned, checksum-verified community email-OTP JAR
│   └── themes/                      # (Phase 4) login theme — not built
├── backend/                         # Spring Boot resource server (JWT validation only)
├── frontend/                        # Angular SPA (public client, Auth Code + PKCE)
├── marshall-mock/                   # (Phase 5) provisioning mock — sketch
└── docs/                            # decision records and per-phase findings
```

The email-OTP JAR in `keycloak/extensions/` is the platform's **only** extension,
and it is not written by us. Provenance, checksum and the evaluation of
alternatives are in `docs/decision-email-otp-extension.md`.
