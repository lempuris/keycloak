#!/bin/sh
# Runs from /docker-entrypoint.d/ before nginx starts; the official nginx
# entrypoint execs the CMD itself once these helpers return.
set -e

# Write runtime configuration into the served assets so one built image can be
# promoted across DEV/UAT/PROD by changing environment variables only - the SPA
# equivalent of the Key Vault secret references in design.md §7.
cat > /usr/share/nginx/html/config.js <<EOF
window.__POC_CONFIG__ = {
  keycloakUrl: "${KEYCLOAK_URL:-http://localhost:8080}",
  realm: "${KEYCLOAK_REALM:-guarantee-gateway}",
  clientId: "${KEYCLOAK_CLIENT_ID:-guarantee-gateway-za}",
  apiUrl: "${API_URL:-http://localhost:8081}"
};
EOF
