# Decision: email OTP extension — and three findings that change the argument

Covers ROADMAP Phase 4 and feeds `design.md` §11 item 1 (email OTP vs TOTP).

**Date:** 2026-08-07
**Status:** Extension pinned and working. **One `design.md` §5 requirement cannot
be met with it.** Recommendation below is to take this to Credeq.

---

## Finding 0 — Keycloak 26.7.1 has no built-in email OTP

Verified against the running server, not from documentation:

- `GET /authentication/authenticator-providers` returns only TOTP/HOTP-style
  authenticators (`auth-otp-form`, `auth-conditional-otp-form`,
  `direct-grant-validate-otp`) plus `auth-recovery-authn-code-form`.
  `reset-credential-email` sends a reset link, not a second-factor code.
- `GET /serverinfo` shows no email-OTP feature flag, disabled or preview.

So `design.md`'s premise holds: email OTP means a community extension, or TOTP.

## Extension evaluated and chosen

**`netzbegruenung/keycloak-mfa-plugins` — `email-authenticator` v26.7.0-2**

| | |
|---|---|
| License | Apache-2.0 |
| Provider id | `email-otp-authenticator` |
| JAR | `netzbegruenung.email-authenticator-v26.7.0-2.jar` (10,942 bytes) |
| SHA-512 | `e507bfe0…badc4f3` — published checksum verified on download |
| Source | `https://github.com/netzbegruenung/keycloak-mfa-plugins/releases/tag/v26.7.0-2` |
| Contents | One `AuthenticatorFactory`, two classes, four locale files, one FreeMarker template. No event listeners, no other SPIs |
| Config | `length` (6), `ttl` (300 s), `forceSecondFactor` — matches `design.md` §5 exactly |

### Alternatives considered

| Extension | Stars | License | Latest | Why not |
|---|---|---|---|---|
| mesutpiskin/keycloak-2fa-email-authenticator | 281 | Apache-2.0 | v26.4.3 → KC 26.5.2 | Active, but builds trail our Keycloak version |
| for-keycloak/email-otp-authenticator | 25 | Unlicense | v1.4.3 → KC 26.3.5 | Unlicense is awkward for enterprise procurement |
| 5-stones/keycloak-email-otp | 51 | MIT | v2.3.0 | Slower release cadence |

**Deciding factor:** netzbegruenung's release versions track Keycloak's exactly
(v26.7.0-x ↔ Keycloak 26.7), which is the only cadence compatible with
`design.md` §1's "bump the image tag, run UAT regression, promote".

## Flow implemented

Exactly `design.md` §5, bound as the realm browser flow, built-in authenticators
plus the one extension:

```
guarantee-gateway-browser
├─ Cookie                         ALTERNATIVE
└─ guarantee-gateway-forms        ALTERNATIVE
   ├─ Username Password Form      REQUIRED
   └─ Email OTP                   REQUIRED   (length 6, ttl 300s)
```

`infrastructure/scripts/test-otp-flow.ps1` — 28 assertions, 27 passing.

Verified working: happy path issues tokens; the OTP email is 6 digits and states
its validity window; the code the user must type matches the emailed one; an
existing SSO cookie skips **both** forms with no second email; a wrong OTP is
rejected and a correct one afterwards still succeeds.

---

## Finding 1 (CRITICAL) — failed OTPs do not count toward lockout

`design.md` §5 requires: *"invalid / expired — retry (failures count toward
lockout)"* and *"3rd failure → permanent lockout"*.

**They do not count.** Measured:

```
3 consecutive wrong OTPs (correct password each time)
  -> numFailures = 0, disabled = False
```

The extension never calls Keycloak's brute-force protector, so the counter never
moves. Three wrong passwords lock the account; three thousand wrong OTPs would
not.

**Consequence:** an attacker who already has a valid password gets unmetered
guesses at a 6-digit code for its full 5-minute life. There is no lockout, and
no per-account rate limit, in that window.

This is a property of the extension, not of our configuration. Fixing it means
writing an authenticator that reports failures — which ROADMAP constraint 2 and
`design.md` §1 forbid. The failing assertion in `test-otp-flow.ps1` §7 is left
red on purpose so the gap stays visible.

**Options, none of them free:**
1. **Switch to built-in TOTP** (`auth-otp-form`). Stock, maintained by Keycloak,
   and removes the platform's only custom component. Whether the built-in OTP
   form reports failures to brute-force detection is **not yet verified here** —
   test it before relying on it.
2. **Accept the risk** with compensating controls: shorter `ttl`, Cloudflare
   rate limiting on the authentication endpoint, Datadog alerting on OTP failure
   volume. Rate limiting at the edge does not bind to the account, so it is
   weaker than a lockout.
3. **Fund a maintained fork** that adds brute-force reporting — reintroduces the
   in-house-code maintenance burden the design set out to avoid.

**Recommendation:** this materially strengthens the TOTP case already open as
`design.md` §11 item 1. Take Finding 1 to Credeq alongside the existing
single-email-channel recovery risk. Option 1 makes the platform 100% stock.

## Finding 2 — the authenticator SPI is internal

Keycloak logs on startup:

```
KC-SERVICES0047: email-otp-authenticator (netzbegruenung...EmailAuthenticatorFactory)
is implementing the internal SPI authenticator. This SPI is internal and may
change without notice
```

Every authenticator extension carries this risk; it is not specific to this one.
It means a Keycloak upgrade can break the login flow with no deprecation cycle.
Concretely, for `design.md` §8: **the UAT regression before any Keycloak upgrade
must include a full OTP login**, and the upgrade cannot proceed until the
extension publishes a matching build. Adopting TOTP removes this dependency.

## Finding 3 — two rapid failures lock an account permanently, not three

`design.md` §6 says "3 failures disables the account". Measured, that is only
true when the attempts are spaced out:

| Attempts | Spacing | Result |
|---|---|---|
| 2 wrong passwords | < 1 s apart | **disabled = True** at numFailures = 2 |
| 2 wrong passwords | 2 s apart | disabled = False, correct login still works |
| 3 wrong passwords | any | disabled = True |

`quickLoginCheckMilliSeconds = 1000` treats two failures inside one second as
scripted, and with `maxTemporaryLockouts = 0` (permanent-lockout mode) that trips
a **permanent** lock at the second failure.

**Consequence for support:** a user who double-submits the login form, or a
client that retries automatically, is permanently locked out after two attempts
and needs a human to unlock them. Worth deciding deliberately: either accept it,
raise `minimumQuickLoginWaitSeconds` handling, or lower
`quickLoginCheckMilliSeconds`. Right now it is an accidental default.

## Finding 4 — Keycloak sends no lockout notification email

`design.md` §6 states: *"Keycloak sends the suspicious-activity email — no links
— via M365."*

**It does not.** With SMTP correctly configured and working (OTP emails arrive
reliably through the same server), locking an account and then attempting a login
produces **no email at all**.

Stock brute-force detection has no user notification. Delivering one requires
either an event-listener SPI (forbidden by ROADMAP constraint 2 and `design.md`
§2) or an external service watching the audit log stream — which is the same
shape as the Marshall provisioning integration, and would fit beside it.

**`design.md` §6 needs correcting**, and the notification needs an owner.

---

## Follow-ups

- [ ] Verify whether built-in TOTP (`auth-otp-form`) reports failures to
      brute-force detection. This decides how strong Option 1 really is.
- [ ] Put Findings 1, 3 and 4 in front of Credeq with the OTP/TOTP sign-off.
- [ ] Correct `design.md` §6 (no lockout email) and §5 (OTP failures do not
      feed the lockout counter with this extension).
- [ ] Add "full OTP login regression" to the pre-upgrade UAT checklist (§8).
- [ ] Reset-credentials flow with OTP re-verification is **not yet built**.
