# Decision: keycloak-config-cli for realm configuration

Closes `design.md` §11 item 6 and the ROADMAP Phase 2 criterion
"Decision recorded: config-cli vs Terraform, with rationale."

**Date:** 2026-08-07
**Status:** Adopted for the PoC. Recommended for the real build **alongside**
Terraform, not instead of it.

## Decision

Use **keycloak-config-cli 6.5.1** to apply realm configuration, and Terraform for
the surrounding Azure infrastructure. Realm config lives in `keycloak/realms/*.json`
and is applied by a one-shot container on every `docker compose up`.

## Why not `--import-realm`

Keycloak's built-in import runs with strategy `IGNORE_EXISTING`:

```
KC-SERVICES0030: Full model import requested. Strategy: IGNORE_EXISTING
```

Once the realm exists, edits to the JSON are silently ignored — the only way to
apply a change was to destroy the database volume. `OVERWRITE_EXISTING` is worse:
it drops and recreates the realm, taking users and sessions with it. Neither is
usable for DEV/UAT/PROD, where realm changes must land on a live realm without
disturbing users.

## Why config-cli over the Terraform provider for *realm* config

Both were considered against `design.md` §8 (Terraform GitOps pipeline).

| | keycloak-config-cli | Terraform provider |
|---|---|---|
| Unit of config | One JSON file per realm, same shape as a realm export | ~40 discrete resources per realm |
| Authentication flows | Declared inline with the rest of the realm | The known friction point — flow executions are ordered, nested and awkward to express as independent resources; `design.md` §8 already flags this |
| State | Stateless; reads the live realm and converges | State file, which for Keycloak contains client secrets (`design.md` §8 already calls out securing it) |
| Drift removal | Configurable per resource type (`full` / `no-delete`) | Strong — anything not in config is destroyed |
| Fit with existing Terraform | Runs as a pipeline step after the infra apply | Single tool, single plan/apply |

The deciding factor is authentication flows. `design.md` §5 specifies a custom
browser flow, and Phase 4 adds an email-OTP execution to it. That is precisely the
part the Terraform provider handles least well, and it is the part most likely to
be edited.

**Recommended split:** Terraform owns the Azure estate (Container Apps, PostgreSQL,
Key Vault, networking) and the Keycloak *instance*; config-cli owns what is inside
the realm. The GitOps pipeline runs `terraform apply` then config-cli, with the
same manual gate before PROD.

## Verified

- Applied to an **existing** realm: updated it in place, users and sessions intact.
- Ran a **second time with no changes: zero create/update/delete operations**
  (6.8 s first run, 1.5 s second). Idempotent.
- The full smoke test (29 checks) passes against the config-cli-managed realm.
- Added a new client (`guarantee-gateway-api`), a client scope with an audience
  mapper, and a service-account client to a **live** realm with no volume reset —
  the exact operation that was impossible before.

## Caveats found

1. **config-cli lags Keycloak releases.** The newest build (6.5.1) targets Keycloak
   **26.1.0**; we run **26.7.1**. It worked — it detects and reports the server
   version — but this is a real coupling: config-cli becomes a gating dependency on
   the "bump the image tag, run UAT regression, promote" upgrade path in
   `design.md` §1. **Check config-cli compatibility before any Keycloak upgrade.**
2. **It is strict about unknown JSON fields.** A stray `serviceAccountsRealmRoles`
   key aborted the whole import. Good for catching typos; it also means comments
   cannot be smuggled into the JSON as extra keys.
3. **`IMPORT_MANAGED_*` defaults to `full`**, which deletes anything absent from the
   file. We set `no-delete` for users, roles, client scopes and authentication
   flows, because `full` would delete Keycloak's own built-ins and — critically —
   **users created by the Marshall provisioning feed**. Production must keep
   `IMPORT_MANAGED_USER=no-delete`: users are not configuration.
   The trade-off is that drift in those categories is not auto-corrected.
4. **Seeding user passwords in config fights the password policy.** With
   `passwordHistory(3)`, re-applying the same seed password logs:
   `Password policy violation detected ... Password was NOT updated`.
   Benign here (the password is unchanged), and it is really evidence for
   `design.md` §4's position that users do not belong in configuration at all.
   The seed users are a PoC convenience only.

## Follow-up for the real build

- Pin the config-cli image by digest, not just tag.
- Decide whether `IMPORT_MANAGED_*` can be tightened to `full` for client scopes
  and flows once the realm stabilises, to get real drift correction.
- Add a pipeline step that runs config-cli in check mode against PROD to detect
  hand-edits before they accumulate.
