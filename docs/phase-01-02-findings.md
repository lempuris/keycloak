# Phase 1 + partial Phase 2 — findings

Date: 2026-08-07
Stack: Keycloak 26.7.1, PostgreSQL 17.10, Mailpit 1.30.6, single node, Docker Compose.

## Acceptance criteria — status

### Phase 1 (Infrastructure) — met

| Criterion | Result |
|---|---|
| Admin console reachable | Yes, http://localhost:8080/admin |
| Health endpoints return ready/live | Yes, on the management port `:9000` |
| Metrics endpoint responds | Yes, `:9000/metrics` |
| Realm data survives restart | Yes |
| **An active user session survives restart** | **Yes — verified with a full container recreate; same `sid` before and after** |

The session test is the meaningful one. `test-session-persistence.ps1 -FullRestart`
logs in, removes and recreates the Keycloak container, then replays the SSO cookies
and asserts Keycloak issues an authorization code *without rendering the login form*.
It also compares the `sid` claim across the restart. Persistent user sessions
(Keycloak 26 default, stored in Postgres) work as `design.md` §2 assumes — which is
what makes ACA's routine replica recycling safe.

### Phase 2 (Core realm as code) — partially met

| Criterion | Result |
|---|---|
| Realm settings match design.md §5/§6 | Yes — 11 assertions in `smoke-test.ps1` |
| Client is public + PKCE S256, no implicit/direct grants | Yes — 6 assertions |
| Test user authenticates end to end | Yes — full Auth Code + PKCE round trip, RS256 JWT, role claim present |
| 3rd failed password disables the account; admin re-enable restores login | Yes — `smoke-test.ps1 -TestLockout` |
| **Realm recreated from Git idempotently, twice** | **No — see below** |
| **Decision recorded: config-cli vs Terraform** | **No — still open** |

## Open issue: realm import is create-only

`--import-realm` runs with Keycloak's `IGNORE_EXISTING` strategy. Once
`guarantee-gateway` exists in Postgres, editing
`keycloak/realms/guarantee-gateway-realm.json` and restarting is a no-op. The log
line to look for is:

```
KC-SERVICES0030: Full model import requested. Strategy: IGNORE_EXISTING
```

Today the only way to apply a realm edit is `poc.ps1 reset` (destroy the volume)
followed by `poc.ps1 up`. That is fine for a laptop and unacceptable for
DEV/UAT/PROD, where realm changes must land on a live realm without dropping users
and sessions.

This is exactly the gap ROADMAP Phase 2 anticipates. `OVERWRITE_EXISTING` is not the
answer either — it drops and recreates the realm, taking users and sessions with it.
The real options are **keycloak-config-cli** (declarative JSON/YAML, merges into a
live realm) or the **Terraform Keycloak provider** (fits the GitOps pipeline in
`design.md` §8, but authentication-flow resources are the part most likely to fight
the provider). `design.md` §11 item 6 already flags this; the prototype has not been
done. **Recommendation: prototype both against the Phase 4 flow specifically**, since
flow config is where the two tools actually differ — everything else is easy in both.

## Note: Secure cookies and non-browser clients

Keycloak sets `AUTH_SESSION_ID` with `SameSite=None`, which obliges it to also set
`Secure`. Browsers treat `http://localhost` as a trustworthy origin and send such
cookies anyway, so the admin console and login page work fine over plain HTTP.
.NET's `CookieContainer` applies the rule strictly and silently drops them, which
breaks any scripted login over HTTP with a `login-error` page.

The test scripts therefore manage cookies by hand (`_common.ps1`). Worth knowing
before someone burns an afternoon on it — and a reminder that the moment the proxy
and TLS arrive in Phase 7, this class of difference disappears.

## Deviations from the roadmap

- **Realm config is plain import JSON, not config-cli or Terraform.** Deliberate:
  it keeps Phase 1 dependency-free and makes the idempotency gap above concrete
  rather than theoretical. Phase 2 proper should replace it.
- **Mailpit is running but nothing sends mail yet.** The realm SMTP settings point
  at it and the inbox is reachable; it gets exercised in Phase 4 (OTP) and by
  password reset.
- **Groups added** (`facility-holders`, `brokers`) beyond the roadmap's role
  requirement, to have a realistic place to hang role assignment.

## Suggested next step

Phase 6 (clustering + cross-replica lockout) is the highest-value item for the Azure
build and does not depend on Phases 3–5 — it needs a second Keycloak replica and a
proxy, both compose-level changes. `design.md` §11 item 5 lists it as required
"before build hardens". Phases 3–5 build the demo surface; Phase 6 de-risks the
architecture. Worth doing 6 early, out of order.
