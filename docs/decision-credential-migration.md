# Credential migration — options for moving passwords to Keycloak

Date: 2026-08-07
Status: **input to a Credeq decision. Nothing implemented; nothing decided here.**
Related: `design.md` §4 and §9, `docs/phase-05-findings.md`, `docs/runbook-user-support.md`.

## The question

Marshall verifies passwords today. After the pivot, users live in Keycloak and Keycloak
verifies passwords. Every existing broker and facility holder therefore needs a working
credential in Keycloak on cutover day — or a way to obtain one.

There are two honest answers: bring the hashes across, or make everyone reset. They
have very different costs, and **which one is even available is a factual question
about Marshall that has not been checked yet.** Check it once, early; it decides the
rest.

## Option A — import the existing password hashes

Keycloak can import pre-hashed credentials. A user representation carries the hash,
salt, algorithm and iteration count, and Keycloak verifies against them from then on.
Nobody resets anything and cutover is invisible to users.

**This works only if Marshall's hashing algorithm is one Keycloak implements
natively.** Keycloak 26 ships `argon2` (the default), `pbkdf2-sha512`, `pbkdf2-sha256`
and `pbkdf2` (SHA-1). If Marshall uses one of those with representable parameters, the
migration is a data exercise.

If Marshall uses anything else — bcrypt and scrypt are the common cases, as is an
in-house scheme — Keycloak cannot verify those hashes without a **custom
`PasswordHashProvider` SPI**. That is a Java plugin inside Keycloak, and it collides
head-on with the minimal-customization principle: it would sit in the credential path
forever, it must be rebuilt and re-verified against every Keycloak upgrade, and a bug
in it is an authentication outage. The usual escape hatch — an authenticator that
verifies against the old hash on first login and re-hashes silently — is the same
plugin problem wearing a different hat, and it keeps a Marshall dependency in the
login path, which is precisely what the pivot removed.

| | |
|---|---|
| **Cost if the algorithm matches** | Low. Export, transform, import, verify a sample. |
| **Cost if it does not** | A permanent custom SPI, or fall back to Option B anyway. |
| **User impact** | None. |
| **Support impact** | None. |
| **Risk** | Password hashes in transit and at rest in an export file — handle as the most sensitive artefact in the project. Old parameters may also be weaker than current policy, so migrated users carry that weakness until they next change their password. |

**What to check, once:** which algorithm, which parameters, and whether the hashes are
exportable at all. Everything else follows.

## Option B — password reset campaign

Users are created in Keycloak with no password and the `UPDATE_PASSWORD` required
action. Keycloak emails each of them a link; they set a password before their first
login. The same Admin API the provisioning service already uses can trigger this
(`PUT /users/{id}` with the required action, or `executeActionsEmail`), so no new
machinery is needed — the mock in this PoC already creates users and could send the
action email instead of accepting a password.

This is the option that always works, and it needs Credeq sign-off because it is
visible to every user.

| | |
|---|---|
| **Cost** | Coordination, not engineering. |
| **User impact** | Every user must act before they can log in. |
| **Support impact** | The spike lands on the support desk, on the same days as the IdP switch. |
| **Risk** | Concentrated, and mostly operational — see below. |

**What actually goes wrong here:**

- **Deliverability decides the outcome.** A reset campaign is a bulk send that looks
  exactly like a phishing wave to spam filters. If mail lands in junk, users cannot
  log in and the support desk absorbs it. Warm up and verify the sending path before
  the campaign, not during it.
- **It trains users to click login links in email.** Directly after an IdP change, when
  a phishing campaign impersonating it would be maximally effective. Announce the
  campaign through another channel first, so the email is expected.
- **Single recovery channel.** The reset link and the login OTP both arrive by email.
  Whoever controls the mailbox controls the account, and the second factor does not
  help against that attacker. This is the same standing risk in `design.md` §11 item 1
  and it applies during the campaign at scale.
- **Lockouts during the spike.** `permanentLockout` plus
  `quickLoginCheckMilliSeconds: 1000` means two rapid failures disable an account
  permanently — see `docs/runbook-user-support.md`. Confused users retrying is exactly
  the traffic that triggers it. Brief support first, and consider whether the campaign
  should be staged rather than big-bang.
- **Action-token lifetime.** Reset links expire (`actionTokenGeneratedByUserLifespan`,
  currently 300 s in the realm config). A link that has expired by the time a user
  opens the mail generates a support call per user. Set this deliberately for the
  campaign; the default is tuned for interactive self-service, not bulk sends.

**Staging beats big-bang.** Waves by broker firm or facility cohort keep the support
load and the mail volume bounded, and let the first wave surface problems while they
are still cheap. It costs a longer parallel-run window.

## Option C — lazy/on-demand migration

Verify against Marshall on first login, then store a Keycloak hash. Users notice
nothing and no hashes move in bulk.

**Rejected under the current constraints.** It needs a custom SPI in the login path and
it reinstates a Marshall dependency during authentication — the two things the Marshall
pivot and constraint 2 exist to prevent. Recorded here so it is visibly considered
rather than overlooked.

## Recommendation

1. **Check Marshall's hashing algorithm first.** It is a single question and it
   collapses the decision. If it is PBKDF2 or Argon2 with representable parameters,
   take Option A: it is cheaper and invisible.
2. **Otherwise take Option B, staged**, and put the operational risks above in the
   sign-off rather than discovering them during the campaign.
3. **Do not take Option A via a custom hash provider.** If the algorithm does not
   match, the honest cost of Option A is a permanent plugin in the credential path,
   and at that price Option B is better.
4. **Whichever is chosen, rehearse it in UAT** against a realistic user count, and
   include support desk and mail deliverability in the rehearsal. The cutover
   rehearsal in Phase 8 is the natural place.

## What this PoC established

- Creating a user through the provisioning feed and having them log in works, and takes
  about a second (`test-provisioning.ps1`). The mechanics of Option B's
  "create user, then get them a credential" are proven; only the campaign is unproven.
- The mock sets a password directly because it is a test fixture. Production onboarding
  has no password to send, which is why the same code path is the natural place to
  trigger the required-action email instead.

## Still open

- Marshall's hashing algorithm and parameters, and whether hashes can be exported.
- Whether existing IdentityServer4 sessions and refresh tokens are invalidated at
  cutover, per client — tracked with the wider cutover sequencing in `design.md` §9.
- Who signs off on a reset campaign, and when the parallel-run window closes.
