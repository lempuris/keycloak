# Phase 5 — Marshall provisioning mock — findings

Date: 2026-08-07
Stack: Keycloak 26.7.1, PostgreSQL 17.10, Node 22.22 / Express 5.1.0, Docker Compose.
Test: `infrastructure/scripts/test-provisioning.ps1` — **50 checks, all passing**.

## What was built

`marshall-mock/` is an ordinary Express service. It holds no Keycloak code, runs in
its own container, and reaches Keycloak only over the Admin API:

```
Marshall  --HTTP-->  marshall-mock  --Admin API (client_credentials)-->  Keycloak
```

The direction is the whole point. Keycloak never calls Marshall, so Marshall being
down delays provisioning but **cannot break a login** — the property that the
rejected user-storage-SPI/federation option could not offer.

| Route | Marshall event | Admin API effect |
|---|---|---|
| `POST /brokers` | onboarded | create user, set password, assign realm role |
| `PATCH /brokers/:username` | details changed | update identity attributes |
| `POST /brokers/:username/deactivate` | offboarded | disable **and** revoke sessions |
| `POST /brokers/:username/reactivate` | reinstated | re-enable |
| `GET /brokers/:username` | — | read-back, used by the tests |
| `DELETE /brokers/:username` | *not a Marshall event* | PoC cleanup only |
| `GET /facilities/:username` | *the read direction* | none — business data served **to** the API |

Delete is deliberately outside the lifecycle contract: Marshall deactivates, it never
deletes, because the audit trail of who did what has to outlive the account.

## Acceptance criteria — status

| Criterion | Result |
|---|---|
| Creating a user in the mock makes them log-in-capable within seconds | **Yes** — measured ~1 s from `POST /brokers` to a completed password + OTP login |
| Deactivating blocks the next login | Yes |
| Deactivating kills live sessions | Yes — sessions drop to zero, confirmed independently via the admin token |
| API access dies within one access-token lifetime | Yes — refresh dies instantly, access token survives to `exp`; bound asserted at ≤ 300 s |
| Service account cannot act outside its scoped roles | Yes — 403 on create-client, realm-update, and the master realm |
| Marshall is on the data path, never the login path | Yes — with the mock stopped, logins and `/api/me` still work; only `/api/facilities` fails, and it fails as 503 |
| Support runbook documented | `docs/runbook-user-support.md` |
| Credential-migration options written up | `docs/decision-credential-migration.md` |

---

## Finding 1 — `fullScopeAllowed: false` silently disables a service account

**Every** Admin API call from the mock returned 403, including the `manage-users`
operations the service account was explicitly granted. The role assignments were
correct; the admin console showed `manage-users`, `view-users` and `view-realm`
mapped to `service-account-marshall-provisioning`.

The token told the real story — no `resource_access` claim at all:

```json
{ "azp": "marshall-provisioning", "scope": "email profile",
  "preferred_username": "service-account-marshall-provisioning" }
```

Keycloak's Admin API authorizes from **the token**, not from the user's stored role
mappings. With `fullScopeAllowed: false` the client's scope filters out every role
that is not explicitly in scope, so the service account authenticates perfectly and
can do nothing.

Fix, without giving up the hardened default:

```json
"clientScopeMappings": {
  "realm-management": [
    { "client": "marshall-provisioning",
      "roles": ["manage-users", "view-users", "view-realm"] }
  ]
}
```

**Why this matters beyond the PoC.** `fullScopeAllowed: false` is the posture we want
everywhere, and the failure mode is 403 on everything — which reads like "the secret
is wrong" or "the role wasn't granted", and sends you looking in the wrong place. Any
service account in the Azure build (provisioning, and later anything automating
Keycloak) needs **both** halves: a role mapping *and* a `clientScopeMappings` entry.
Grant the roles and walk away and it will fail in DEV exactly as it failed here.

## Finding 2 — health-ready is not the same as serving

After `docker compose restart keycloak`, `/health/ready` on the management port
reports `UP` while the public port still answers every request with:

```
Bootstrap in progress. Retry in 1 seconds.
```

This made `test-session-persistence.ps1` fail with "session was lost". The session was
fine — the same `sid` came back once the realm endpoint actually served. The test now
waits for the realm's discovery document, not just the container healthcheck
(`Wait-ForRealmEndpoint` in `_common.ps1`), and passes 7/7.

**Carry this into the Azure build.** ACA shifts traffic on the readiness probe. If the
probe is `/health/ready` on `:9000`, ACA can route real logins to a replica that
answers "Bootstrap in progress" — visible to users as a failed login during every
rolling restart and every scale-out. Point the ACA readiness probe at something on the
public port that only answers when the realm is genuinely serving, and verify it
during the Phase 6 clustering work.

## Finding 3 — deactivation is two operations, and the second one is the one that counts

Disabling the account stops the **next** login and nothing else. Sessions issued
before the change survive until the SSO session expires — up to 10 hours under the
`design.md` §5 lifetimes. The mock therefore always follows `enabled: false` with
`POST /users/{id}/logout`.

Measured behaviour after deactivation:

| Thing | Result | Why |
|---|---|---|
| Next login | blocked immediately | account disabled |
| Live SSO sessions | zero immediately | admin logout |
| Refresh token | `400 invalid_grant` immediately | session gone |
| **Already-issued access token** | **still accepted by the API** | stateless JWT — nothing consults Keycloak |

That last row is not a bug, and it is the concrete justification for the 5-minute
`accessTokenLifespan`. **Residual access after offboarding is exactly one access-token
lifetime**, and the only lever that shortens it is the lifetime itself. Anyone
proposing to raise it to reduce token traffic is trading directly against how long a
terminated broker keeps working API access.

Run `test-provisioning.ps1 -ProveTokenExpiry` to watch the token die instead of
trusting the arithmetic; it adds ~5 minutes.

## Finding 4 — config-as-code and the provisioning feed coexist, but only because of one setting

The realm JSON in Git does not mention provisioned brokers, so a "make reality match
the file" run is precisely where they could vanish. Re-applying the realm config with
a provisioned user present leaves that user intact and still able to log in — asserted
in the test — **because `IMPORT_MANAGED_USER=no-delete` is set**. Setting it to `full`
to tidy the realm up would delete every user the provisioning feed ever created.

Users are not configuration. The realm file owns clients, flows, roles and settings;
the provisioning feed owns users. The seeded users in the realm JSON are a PoC
convenience and must not survive into production.

## Finding 5 — the pivot's central claim, now demonstrated rather than asserted

Marshall has **two** relationships with the platform, and only one of them was
modelled at first:

```
provisioning:  Marshall  --->  Keycloak     (writes, occasional)
facilities:    API       --->  Marshall     (reads, every request)
```

`FacilityDirectory` used to be a hardcoded map inside the API, which meant the
second arrow existed only on paper. It now makes a real HTTP call to the mock,
with a 2 s connect and 3 s read timeout — **timeouts are not optional on a call
in the request path**, because a hung Marshall would otherwise exhaust the API's
threads and turn one system's outage into two.

Stopping the mock and re-running the tests gives the property the whole Marshall
pivot was chosen for:

| With Marshall down | Result |
|---|---|
| Log in (password + OTP) | **Works** |
| `GET /api/me` | **200** |
| `GET /api/facilities` | **503** |
| Marshall restarted | back to 200, data intact |

The failure is a **503, not an empty 200**. That distinction matters more than it
looks: an empty list is a truthful answer for a newly provisioned broker who has
no facilities yet, so returning one on failure would tell an existing user they
have no facilities and hide the outage from monitoring at the same time. "I don't
know" and "none" are different answers and the API must not conflate them.

This is also the concrete counter-argument to reviving federation. Under the
rejected user-storage-SPI design, the top row of that table would read **fails**
— Marshall would be in the login path, and its outage would lock everybody out
rather than degrade one screen.

## Finding 6 — two things that cost time and are worth knowing

- **Keycloak `description` fields are `varchar(255)`.** A longer client description
  makes the Admin API return `500 unknown_error`; the cause is only visible in the
  Keycloak container log as `value too long for type character varying(255)`. It looks
  like a config-cli bug and is not one.
- **HTTP method tokens are case-sensitive.** .NET's `HttpMethod` does not normalize
  them, so `Patch`/`Delete` go out verbatim and Node's parser rejects them with a bare
  `400` *before Express runs* — the server logs nothing, so it reads as a routing bug.
  `Get`/`Post` survive because .NET Framework normalizes its own table of known verbs.
  Test helpers now uppercase the verb.

---

## Deviations and gaps

- **The mock has no authentication of its own.** In the real build Marshall must
  authenticate to the provisioning service (mTLS or a signed webhook) and the service
  must not be publicly reachable. Here it is exposed on `localhost:8090` so the test
  script can drive it.
- **`POST /brokers` accepts a password.** Real onboarding has no password to send —
  see `docs/decision-credential-migration.md`.
- **The support-desk role is configured but not exercised end to end.** The
  `support-desk` group and its scoped `realm-management` roles are applied from the
  realm file and asserted (including that it does *not* carry `impersonation`), but
  nobody logged into the admin console as a member. Realm-admin console login runs
  through the `guarantee-gateway` browser flow, OTP and all, and belongs with the
  Phase 7 work that moves the admin console to its own hostname.
- **No delivery guarantees.** The mock is fire-and-forget: a failed Admin API call
  returns an error to the caller and nothing retries. A real feed needs retries with
  backoff, idempotency on replay, and a reconciliation job to close the drift window —
  which is the open "webhook vs sync job" question in `design.md`.

## Suggested next step

**Phase 6 (clustering + cross-replica lockout).** It is the highest-value item for the
Azure build, it is independent of Phases 4–5, and Finding 2 has just added a second
question for it to answer: what the ACA readiness probe should actually point at.
