# Runbook — user support in Keycloak

Date: 2026-08-07
Applies to: realm `guarantee-gateway`, Keycloak 26.7.1.

This is the change-management cost of the Marshall pivot. Password resets, unlocks
and disables used to happen in the Marshall UI. Users now live in Keycloak, so these
move to the Keycloak admin console — a different tool, a different login, and a
different mental model for the support desk.

## Who does this, and with what

Support works in the **realm** admin console, never the master realm:

```
http://localhost:8080/admin/guarantee-gateway/console      (PoC)
https://sa.identity.credeq.com/admin/guarantee-gateway/console   (target)
```

Membership of the **`support-desk`** group grants exactly:

| Role | What it buys |
|---|---|
| `view-realm` | see the realm at all (console needs it) |
| `view-users` | find a user |
| `manage-users` | enable/disable, reset credentials, clear lockouts, end sessions |
| `view-events` | see *why* an account locked |

Deliberately **not** granted:

| Role | Why not |
|---|---|
| `impersonation` | support could log in as a facility holder and act on their guarantees |
| `manage-realm` | brute-force settings and token lifetimes are code, not a console toggle |
| `manage-clients` | redirect URIs and PKCE are security config, changed through Git |
| `manage-authorization` | the login flow is code |

The group and its scoping are applied from `keycloak/realms/guarantee-gateway.json`
and asserted by `test-provisioning.ps1` (section 9), including the absence of
`impersonation`. Adding a member is a runtime action; changing what the group *can do*
is a config change that goes through Git.

> Not yet exercised end to end: nobody has logged into the console as a `support-desk`
> member. Realm-admin console login runs through the `guarantee-gateway` browser flow,
> OTP included. Confirm this alongside the Phase 7 work that moves the admin console to
> its own hostname — including which second factor support staff themselves use.

---

## 1. "I'm locked out"

**First, read the situation correctly.** The realm runs `permanentLockout` with
`failureFactor: 3`, so a locked account is a **disabled** account — it will not come
back on its own, and there is no wait-it-out option.

It is also frequently **not** three attempts. `quickLoginCheckMilliSeconds: 1000`
means two failures less than a second apart lock the account permanently. A
double-clicked sign-in button or a retrying client does it. Expect legitimate users
here, and do not treat a lockout as evidence of an attack on its own.

**Keycloak sends no notification.** `design.md` §6 says the user gets a
suspicious-activity email; stock brute-force detection has no such feature and none is
sent. The first anyone knows is the user calling.

**Check what happened** — Realm → *Sessions*/*Events* → filter by user, look for
`LOGIN_ERROR` with `invalid_user_credentials`. Timestamps under a second apart mean
quick-login detection, not a guessing attack.

**Unlock** — Users → find the user → *Details*:

1. Set **Enabled** back on.
2. Clear the failure counter, or the next failure locks them again immediately.
   The console exposes this on the user's page when a lockout is recorded; the
   underlying calls, which is what the PoC scripts use, are:

   ```
   DELETE /admin/realms/guarantee-gateway/attack-detection/brute-force/users/{id}
   PUT    /admin/realms/guarantee-gateway/users/{id}      { "enabled": true }
   ```

Both together are the unlock. Re-enabling without clearing the counter is the common
half-fix that produces a repeat call ten minutes later.

**Escalate** if the events show many failures from unfamiliar addresses, or the same
user locks repeatedly after a clean unlock.

## 2. "I need my password reset"

Two options; prefer the first.

**Self-service (preferred).** Send the user to *Forgot password?* on the login page.
Keycloak emails a reset link, and the flow is the same one everyone else uses.

**Support-initiated.** Users → find the user → *Credentials* → **Reset password**.
Leave **Temporary** on so Keycloak forces a change at next login. Never read a
password out to a caller; never set one they did not choose themselves.

> **Recovery-channel risk, flagged for Credeq sign-off.** Both the password reset link
> and the login OTP arrive by email. Anyone holding the mailbox holds the account —
> the second factor adds nothing against that one attacker. This is a standing input
> to the TOTP decision (`design.md` §11 item 1), not something support can mitigate.

Verify the caller before either path. The account is the only thing standing between a
caller and someone else's guarantee facilities.

## 3. "Disable this account now"

**Normally this is Marshall's job, not support's.** Marshall is the system of record;
offboarding there flows through the provisioning feed automatically. Doing it by hand
in Keycloak makes the two systems disagree, and the next Marshall event may undo it.

Use the console only for a genuine emergency — suspected compromise, before Marshall
can be updated. Then:

1. Users → *Details* → **Enabled** off. This blocks the **next** login only.
2. Users → *Sessions* → **Sign out** all sessions. **Do not skip this.** Without it,
   existing sessions live on for up to the 10-hour SSO maximum.
3. Tell whoever owns the Marshall record, so the systems reconverge.

**What is still true after both steps:** an access token already issued keeps working
until it expires — at most 5 minutes. That window is unavoidable with stateless JWT
validation and is the reason `accessTokenLifespan` is short. If someone needs access
cut dead in under 5 minutes, that is a design conversation, not a runbook step.

## 4. "The user doesn't exist in Keycloak"

Users reach Keycloak through the provisioning feed. If a broker exists in Marshall but
not here, the feed did not run or it failed — a provisioning incident, not a support
one. Do **not** hand-create the user to unblock the call: it will exist without the
Marshall linkage, and the next sync will not know about it. Escalate to whoever owns
the feed.

---

## Quick reference

| Symptom | Action | Watch out for |
|---|---|---|
| Locked out | Re-enable **and** clear the brute-force counter | Doing only one of the two |
| Locked out repeatedly | Check events; likely quick-login detection at 2 rapid failures | Assuming an attack |
| Forgot password | Self-service reset link | Reading a password to a caller |
| Compromised account | Disable **and** sign out sessions | Skipping the sign-out |
| Suspected compromise, immediate | Both of the above | Access tokens live up to 5 more minutes |
| Missing user | Escalate to the provisioning feed owner | Hand-creating the user |
| "Just make them an admin" | Refuse; role changes are Git changes | Console edits that Git will overwrite |
