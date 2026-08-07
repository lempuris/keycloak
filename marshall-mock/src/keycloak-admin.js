/**
 * Thin Keycloak Admin API client.
 *
 * design.md §4: this is ordinary external service code. Nothing here runs inside
 * Keycloak, and Keycloak never calls Marshall — so Marshall being down cannot
 * affect logins.
 *
 * Authentication is the client_credentials grant against a dedicated
 * service-account client scoped to realm-management/manage-users. It is
 * deliberately NOT the master admin.
 */

const KEYCLOAK_URL = process.env.KEYCLOAK_URL ?? 'http://keycloak:8080';
const REALM = process.env.KEYCLOAK_REALM ?? 'guarantee-gateway';
const CLIENT_ID = process.env.KEYCLOAK_CLIENT_ID ?? 'marshall-provisioning';
const CLIENT_SECRET = process.env.KEYCLOAK_CLIENT_SECRET ?? '';

let cached = { token: null, expiresAt: 0 };

export async function getServiceToken() {
  if (cached.token && Date.now() < cached.expiresAt) {
    return cached.token;
  }

  const response = await fetch(`${KEYCLOAK_URL}/realms/${REALM}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    }),
  });

  if (!response.ok) {
    throw new Error(`Service-account token request failed: ${response.status} ${await response.text()}`);
  }

  const body = await response.json();
  // Refresh a little early so an in-flight request never uses an expired token.
  cached = { token: body.access_token, expiresAt: Date.now() + (body.expires_in - 15) * 1000 };
  return cached.token;
}

export async function adminFetch(path, options = {}) {
  const token = await getServiceToken();
  const response = await fetch(`${KEYCLOAK_URL}/admin/realms/${REALM}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      ...(options.headers ?? {}),
    },
  });
  return response;
}

async function adminJson(path, options) {
  const response = await adminFetch(path, options);
  if (!response.ok) {
    throw Object.assign(new Error(`Admin API ${path} -> ${response.status}`), {
      status: response.status,
      detail: await response.text(),
    });
  }
  if (response.status === 204 || response.headers.get('content-length') === '0') return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

export async function findUser(username) {
  const users = await adminJson(`/users?username=${encodeURIComponent(username)}&exact=true`);
  return users?.[0] ?? null;
}

export async function createUser({ username, email, firstName, lastName, password, realmRole }) {
  const response = await adminFetch('/users', {
    method: 'POST',
    body: JSON.stringify({
      username,
      email: email ?? username,
      firstName,
      lastName,
      enabled: true,
      emailVerified: true,
      credentials: password ? [{ type: 'password', value: password, temporary: false }] : [],
    }),
  });

  if (response.status === 409) {
    throw Object.assign(new Error('User already exists in Keycloak'), { status: 409 });
  }
  if (!response.ok) {
    throw Object.assign(new Error('Create failed'), { status: response.status, detail: await response.text() });
  }

  const user = await findUser(username);
  if (realmRole) await assignRealmRole(user.id, realmRole);
  return user;
}

export async function assignRealmRole(userId, roleName) {
  const role = await adminJson(`/roles/${encodeURIComponent(roleName)}`);
  await adminJson(`/users/${userId}/role-mappings/realm`, {
    method: 'POST',
    body: JSON.stringify([{ id: role.id, name: role.name }]),
  });
}

export async function updateUser(userId, changes) {
  await adminJson(`/users/${userId}`, { method: 'PUT', body: JSON.stringify(changes) });
}

export async function getUserSessions(userId) {
  return (await adminJson(`/users/${userId}/sessions`)) ?? [];
}

/**
 * Deactivation is two steps, and the second one matters.
 *
 * Disabling the account stops the NEXT login. It does nothing to sessions that
 * already exist, so without the logout call the user keeps working until their
 * SSO session expires — up to 10 hours (design.md §5). Revoking sessions also
 * kills the refresh token, which is what actually bounds API access to one
 * access-token lifetime.
 */
export async function deactivateUser(userId) {
  await updateUser(userId, { enabled: false });
  await adminJson(`/users/${userId}/logout`, { method: 'POST' });
}

export async function reactivateUser(userId) {
  await updateUser(userId, { enabled: true });
}

export async function deleteUser(userId) {
  await adminJson(`/users/${userId}`, { method: 'DELETE' });
}
