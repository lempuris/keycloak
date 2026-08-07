/**
 * Facility linkage — the business data Marshall owns (design.md §4).
 *
 * This lives here, not in the API and not in Keycloak, and that placement is the
 * point. Keycloak issues identity and a coarse role; which facilities a user is
 * linked to is a business fact belonging to the system of record, and the API
 * resolves it per request using the identity in the token.
 *
 * Keyed by username rather than the Keycloak user id (`sub`), which is what
 * production would use. The PoC's seed users get a fresh `sub` every time the
 * database volume is reset, which would make this data useless on every reset.
 */

const FACILITIES_BY_USERNAME = {
  'thabo.mokoena@example.com': [
    { reference: 'FAC-2026-0041', holder: 'Mokoena Construction (Pty) Ltd', limit: 'ZAR 4 500 000', status: 'ACTIVE' },
    { reference: 'FAC-2026-0087', holder: 'Mokoena Civils JV', limit: 'ZAR 1 250 000', status: 'UNDER_REVIEW' },
  ],
  'lerato.dlamini@example.com': [
    { reference: 'FAC-2026-0041', holder: 'Mokoena Construction (Pty) Ltd', limit: 'ZAR 4 500 000', status: 'ACTIVE' },
    { reference: 'FAC-2026-0112', holder: 'Sibanye Logistics CC', limit: 'ZAR 800 000', status: 'ACTIVE' },
    { reference: 'FAC-2026-0130', holder: 'Thabiso Plant Hire', limit: 'ZAR 2 100 000', status: 'SUSPENDED' },
  ],
};

/**
 * A user with no linked facilities is a normal answer, not an error — a newly
 * provisioned broker has none until Marshall links them. The API must be able to
 * tell that apart from "Marshall is unreachable", so this returns an empty list
 * rather than a 404.
 */
export function findFacilities(username) {
  return FACILITIES_BY_USERNAME[username] ?? [];
}
