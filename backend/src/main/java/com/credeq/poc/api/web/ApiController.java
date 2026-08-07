package com.credeq.poc.api.web;

import java.time.Instant;
import java.util.List;
import java.util.Map;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import com.credeq.poc.api.facility.FacilityDirectory;

@RestController
@RequestMapping("/api")
public class ApiController {

    private final FacilityDirectory facilityDirectory;

    public ApiController(FacilityDirectory facilityDirectory) {
        this.facilityDirectory = facilityDirectory;
    }

    /** Unauthenticated - lets the SPA confirm the API is reachable before login. */
    @GetMapping("/public/info")
    public Map<String, Object> info() {
        return Map.of(
                "service", "guarantee-gateway-api",
                "authenticated", false,
                "time", Instant.now().toString());
    }

    /** Any authenticated user. Echoes the claims the API actually relies on. */
    @GetMapping("/me")
    public Map<String, Object> me(@AuthenticationPrincipal Jwt jwt) {
        return Map.of(
                "subject", jwt.getSubject(),
                "username", jwt.getClaimAsString("preferred_username"),
                "email", jwt.getClaimAsString("email"),
                "issuer", jwt.getIssuer().toString(),
                "audience", jwt.getAudience(),
                "roles", realmRoles(jwt),
                "issuedAt", String.valueOf(jwt.getIssuedAt()),
                "expiresAt", String.valueOf(jwt.getExpiresAt()));
    }

    /**
     * Facility-holder only. Demonstrates design.md §4: the token carries identity,
     * the API resolves business data from the system of record using it.
     */
    @GetMapping("/facilities")
    @PreAuthorize("hasRole('facility-holder')")
    public Map<String, Object> facilities(@AuthenticationPrincipal Jwt jwt) {
        String username = jwt.getClaimAsString("preferred_username");
        return Map.of(
                "resolvedFrom", Map.of("sub", jwt.getSubject(), "preferred_username", username),
                "note", "Facility linkage came from the business system, not from a token claim.",
                "facilities", facilityDirectory.findForUser(username));
    }

    /** Broker only. Exists so the SPA can show a 403 against the other role. */
    @GetMapping("/broker/portfolio")
    @PreAuthorize("hasRole('broker')")
    public Map<String, Object> brokerPortfolio(@AuthenticationPrincipal Jwt jwt) {
        String username = jwt.getClaimAsString("preferred_username");
        List<FacilityDirectory.Facility> managed = facilityDirectory.findForUser(username);
        return Map.of(
                "broker", username,
                "managedFacilities", managed,
                "totalUnderManagement", managed.size());
    }

    @SuppressWarnings("unchecked")
    private static List<String> realmRoles(Jwt jwt) {
        Map<String, Object> realmAccess = jwt.getClaimAsMap("realm_access");
        if (realmAccess == null) {
            return List.of();
        }
        Object roles = realmAccess.get("roles");
        return roles instanceof List<?> list ? (List<String>) list : List.of();
    }
}
