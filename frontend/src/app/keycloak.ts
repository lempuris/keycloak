import Keycloak from 'keycloak-js';

/**
 * Runtime configuration. Injected by nginx at container start from environment
 * variables (see docker-entrypoint.sh), so the same image can be promoted
 * across DEV/UAT/PROD without a rebuild - the pattern the real SPA needs for
 * the GitOps pipeline in design.md §8.
 */
declare global {
  interface Window {
    __POC_CONFIG__?: {
      keycloakUrl: string;
      realm: string;
      clientId: string;
      apiUrl: string;
    };
  }
}

const config = window.__POC_CONFIG__ ?? {
  keycloakUrl: 'http://localhost:8080',
  realm: 'guarantee-gateway',
  clientId: 'guarantee-gateway-za',
  apiUrl: 'http://localhost:8081',
};

export const apiUrl = config.apiUrl;

export const keycloak = new Keycloak({
  url: config.keycloakUrl,
  realm: config.realm,
  clientId: config.clientId,
});

/**
 * `check-sso` means: if there is already an SSO session, adopt it silently;
 * otherwise carry on unauthenticated rather than forcing a login redirect.
 * The silent check runs in a hidden iframe so a returning user never sees a flash
 * of the login page.
 *
 * PKCE S256 is mandatory here - the realm's client rejects a code exchange
 * without a verifier.
 */
export async function initKeycloak(): Promise<boolean> {
  return keycloak.init({
    onLoad: 'check-sso',
    pkceMethod: 'S256',
    checkLoginIframe: false,
    silentCheckSsoRedirectUri: `${window.location.origin}/silent-check-sso.html`,
  });
}

/**
 * Refreshes the access token when it is within 30 s of expiry.
 *
 * With a 5-minute access token (design.md §5) this is what keeps the SPA
 * working without the user noticing. Keycloak rotates the refresh token on
 * every use, so the old one is dead immediately after this call.
 */
export async function withFreshToken(): Promise<string | undefined> {
  try {
    await keycloak.updateToken(30);
  } catch {
    // Refresh failed - the session is gone (expired, revoked, or the user was
    // deactivated by the Marshall feed). Force a fresh login.
    await keycloak.login();
  }
  return keycloak.token;
}

export function realmRoles(): string[] {
  return keycloak.tokenParsed?.['realm_access']?.roles ?? [];
}

export function hasRole(role: string): boolean {
  return realmRoles().includes(role);
}
