/**
 * Marshall provisioning mock (ROADMAP Phase 5).
 *
 * Stands in for the broker lifecycle feed that Marshall will own. Marshall stays
 * the business system of record; the *users* live in Keycloak (design.md §4), so
 * every lifecycle event has to be pushed here rather than resolved at login time.
 *
 * The shape is the point of this service, not the code:
 *
 *   Marshall  --HTTP-->  this service  --Admin API-->  Keycloak
 *
 * Note the direction. Keycloak never calls Marshall, so Marshall being down
 * delays provisioning but cannot break a login. That is the whole reason the
 * federation/user-storage-SPI option was dropped.
 *
 * NOT production code. There is no authentication on these routes: in the real
 * build Marshall would authenticate to this service (mTLS or a signed webhook)
 * and the service would run on a private network. Here it is exposed on
 * localhost so the test script can drive it.
 */

import express from 'express';

import { findFacilities } from './facilities.js';
import {
  createUser,
  deactivateUser,
  deleteUser,
  findUser,
  getUserSessions,
  reactivateUser,
  updateUser,
} from './keycloak-admin.js';

const PORT = Number(process.env.PORT ?? 8090);
const app = express();

app.use(express.json());

// Every request is logged as one structured JSON line. Same discipline as the
// Keycloak audit path (design.md §2): logs are the integration point, not a
// plugin that ships events somewhere.
app.use((req, res, next) => {
  const startedAt = Date.now();
  res.on('finish', () => {
    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        service: 'marshall-mock',
        method: req.method,
        path: req.originalUrl,
        status: res.statusCode,
        durationMs: Date.now() - startedAt,
      }),
    );
  });
  next();
});

app.get('/health', (_req, res) => res.json({ status: 'UP' }));

/**
 * Facility linkage for a user — the *other* direction of the Marshall
 * relationship, and the one that runs on every request.
 *
 *   provisioning:  Marshall  --->  Keycloak     (writes, occasional)
 *   this endpoint: API       --->  Marshall     (reads, per request)
 *
 * The API calls this instead of carrying facilities in the token. Business data
 * in a JWT is a copy: it goes stale the moment Marshall changes, stays valid
 * until the token expires, and is readable by anyone holding the token.
 *
 * Note what is NOT here: no token is validated and no authorization happens.
 * The API has already done that. This answers "what is this user linked to",
 * which is a business question, and the split is deliberate.
 */
app.get('/facilities/:username', (req, res) => {
  res.json({
    username: req.params.username,
    facilities: findFacilities(req.params.username),
  });
});

/**
 * Resolves the Keycloak user behind a Marshall broker identifier.
 * Returns null and answers 404 itself when there is no match.
 */
async function requireUser(username, res) {
  const user = await findUser(username);
  if (!user) {
    res.status(404).json({ error: 'No such user in Keycloak', username });
    return null;
  }
  return user;
}

function toBrokerView(user, sessions) {
  return {
    username: user.username,
    keycloakId: user.id,
    email: user.email,
    firstName: user.firstName,
    lastName: user.lastName,
    enabled: user.enabled,
    ...(sessions ? { activeSessions: sessions.length } : {}),
  };
}

/** Read-back, so the tests assert against Keycloak rather than against our own reply. */
app.get('/brokers/:username', async (req, res) => {
  const user = await requireUser(req.params.username, res);
  if (!user) return;
  res.json(toBrokerView(user, await getUserSessions(user.id)));
});

/**
 * Marshall onboarded a broker.
 *
 * The password here is a PoC shortcut. Real onboarding has no password to send:
 * either Keycloak emails an update-password action, or the broker goes through
 * the reset flow. Which of those applies at cutover is the open credential
 * -migration question — see docs/phase-05-findings.md.
 */
app.post('/brokers', async (req, res) => {
  const { username, email, firstName, lastName, password, realmRole } = req.body ?? {};
  if (!username) {
    return res.status(400).json({ error: 'username is required' });
  }
  const user = await createUser({ username, email, firstName, lastName, password, realmRole });
  res.status(201).json(toBrokerView(user));
});

/** Marshall changed a broker's details. Identity attributes only — never roles-as-business-data. */
app.patch('/brokers/:username', async (req, res) => {
  const user = await requireUser(req.params.username, res);
  if (!user) return;

  const { email, firstName, lastName } = req.body ?? {};
  const changes = {};
  if (email !== undefined) changes.email = email;
  if (firstName !== undefined) changes.firstName = firstName;
  if (lastName !== undefined) changes.lastName = lastName;
  if (Object.keys(changes).length === 0) {
    return res.status(400).json({ error: 'No supported fields to update (email, firstName, lastName)' });
  }

  await updateUser(user.id, changes);
  res.json(toBrokerView(await findUser(user.username)));
});

/**
 * Marshall offboarded a broker — the event that actually matters.
 *
 * Disabling alone only stops the NEXT login; the revocation is what bounds
 * existing access. See the comment on deactivateUser for why both steps exist.
 */
app.post('/brokers/:username/deactivate', async (req, res) => {
  const user = await requireUser(req.params.username, res);
  if (!user) return;

  const sessionsBefore = await getUserSessions(user.id);
  await deactivateUser(user.id);

  res.json({
    ...toBrokerView(await findUser(user.username), await getUserSessions(user.id)),
    revokedSessions: sessionsBefore.length,
  });
});

app.post('/brokers/:username/reactivate', async (req, res) => {
  const user = await requireUser(req.params.username, res);
  if (!user) return;
  await reactivateUser(user.id);
  res.json(toBrokerView(await findUser(user.username)));
});

/**
 * PoC housekeeping only — deliberately not part of the lifecycle contract.
 * Marshall deactivates; it never deletes, because the audit trail of who did
 * what has to outlive the account.
 */
app.delete('/brokers/:username', async (req, res) => {
  const user = await requireUser(req.params.username, res);
  if (!user) return;
  await deleteUser(user.id);
  res.status(204).end();
});

// Express 5 forwards rejected promises from async handlers here.
// `status` is set by keycloak-admin.js on Admin API failures, so a 403 from
// Keycloak surfaces as a 403 rather than a generic 500 — which is what makes
// the least-privilege test readable.
app.use((err, _req, res, _next) => {
  const status = err.status && err.status >= 400 ? err.status : 500;
  console.error(
    JSON.stringify({
      ts: new Date().toISOString(),
      service: 'marshall-mock',
      level: 'error',
      status,
      message: err.message,
      detail: err.detail,
    }),
  );
  res.status(status).json({ error: err.message, detail: err.detail });
});

app.listen(PORT, () => {
  console.log(
    JSON.stringify({
      ts: new Date().toISOString(),
      service: 'marshall-mock',
      message: `listening on ${PORT}`,
      keycloak: process.env.KEYCLOAK_URL ?? 'http://keycloak:8080',
      realm: process.env.KEYCLOAK_REALM ?? 'guarantee-gateway',
    }),
  );
});
