import { bootstrapApplication } from '@angular/platform-browser';

import { AppComponent } from './app/app.component';
import { initKeycloak } from './app/keycloak';

/**
 * Keycloak is initialised *before* the app bootstraps so the first render
 * already knows whether there is a session. Bootstrapping first would flash the
 * signed-out UI at returning users on every page load.
 */
initKeycloak()
  .catch((error) => {
    console.error('Keycloak initialisation failed', error);
    return false;
  })
  .then(() => bootstrapApplication(AppComponent))
  .catch((error) => console.error('Bootstrap failed', error));
