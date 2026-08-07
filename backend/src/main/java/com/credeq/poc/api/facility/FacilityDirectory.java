package com.credeq.poc.api.facility;

import java.util.List;
import java.util.Map;

import org.springframework.stereotype.Component;

/**
 * Stand-in for Marshall, the business system of record.
 *
 * <p>This exists to demonstrate the ownership split in design.md §4: facility
 * linkage lives in the business system and is resolved by the API from the
 * identity in the token. It is deliberately <em>not</em> synced into the token —
 * adding a "facilities" claim would couple token issuance to Marshall, bloat the
 * JWT, and leave stale data valid until the token expires.
 *
 * <p>In production the lookup key is the immutable Keycloak user id ({@code sub}).
 * Here it is keyed by username, because the PoC's seed users get a fresh {@code sub}
 * every time the database volume is reset, which would make the demo data useless.
 */
@Component
public class FacilityDirectory {

    private static final Map<String, List<Facility>> FACILITIES_BY_USERNAME = Map.of(
            "thabo.mokoena@example.com", List.of(
                    new Facility("FAC-2026-0041", "Mokoena Construction (Pty) Ltd", "ZAR 4 500 000", "ACTIVE"),
                    new Facility("FAC-2026-0087", "Mokoena Civils JV", "ZAR 1 250 000", "UNDER_REVIEW")),
            "lerato.dlamini@example.com", List.of(
                    new Facility("FAC-2026-0041", "Mokoena Construction (Pty) Ltd", "ZAR 4 500 000", "ACTIVE"),
                    new Facility("FAC-2026-0112", "Sibanye Logistics CC", "ZAR 800 000", "ACTIVE"),
                    new Facility("FAC-2026-0130", "Thabiso Plant Hire", "ZAR 2 100 000", "SUSPENDED")));

    public List<Facility> findForUser(String username) {
        return FACILITIES_BY_USERNAME.getOrDefault(username, List.of());
    }

    public record Facility(String reference, String holder, String limit, String status) {
    }
}
