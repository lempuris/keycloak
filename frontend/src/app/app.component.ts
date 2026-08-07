import { Component, signal } from '@angular/core';

import { apiUrl, hasRole, keycloak, realmRoles, withFreshToken } from './keycloak';

interface CallResult {
  path: string;
  status: number;
  body: string;
}

@Component({
  selector: 'app-root',
  standalone: true,
  templateUrl: './app.component.html',
})
export class AppComponent {
  readonly authenticated = signal(keycloak.authenticated ?? false);
  readonly result = signal<CallResult | null>(null);
  readonly busy = signal(false);

  readonly username = signal<string>(keycloak.tokenParsed?.['preferred_username'] ?? '');
  readonly roles = signal<string[]>(realmRoles());

  readonly isFacilityHolder = signal(hasRole('facility-holder'));
  readonly isBroker = signal(hasRole('broker'));

  login(): void {
    void keycloak.login();
  }

  logout(): void {
    // RP-initiated logout: ends the Keycloak SSO session, not just the local
    // token. Without the redirect the browser would keep a live SSO cookie and
    // the next `check-sso` would silently log the user back in.
    void keycloak.logout({ redirectUri: window.location.origin });
  }

  /** Shows the raw access token claims - handy when explaining JWTs in a demo. */
  showToken(): void {
    this.result.set({
      path: 'access token (decoded)',
      status: 200,
      body: JSON.stringify(keycloak.tokenParsed, null, 2),
    });
  }

  async call(path: string): Promise<void> {
    this.busy.set(true);
    try {
      const token = await withFreshToken();
      const response = await fetch(`${apiUrl}${path}`, {
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      });
      const text = await response.text();
      let body = text;
      try {
        body = JSON.stringify(JSON.parse(text), null, 2);
      } catch {
        // Non-JSON error body (e.g. an empty 403) - show it as-is.
      }
      this.result.set({ path, status: response.status, body });
    } catch (error) {
      this.result.set({ path, status: 0, body: String(error) });
    } finally {
      this.busy.set(false);
    }
  }

  statusClass(status: number): string {
    if (status >= 200 && status < 300) return 'ok';
    if (status === 401 || status === 403) return 'denied';
    return 'error';
  }
}
