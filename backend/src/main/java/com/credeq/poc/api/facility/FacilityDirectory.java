package com.credeq.poc.api.facility;

import java.time.Duration;
import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

/**
 * Reads facility linkage from Marshall, the business system of record.
 *
 * <p>This is the read half of the Marshall relationship in design.md §4, and it
 * runs on every request. The write half — user lifecycle pushed into Keycloak —
 * is the provisioning feed, and the two are unrelated:
 *
 * <pre>
 *   provisioning:  Marshall  ---&gt;  Keycloak    (writes, occasional)
 *   this class:    API       ---&gt;  Marshall    (reads, per request)
 * </pre>
 *
 * <p>The lookup key is the identity in the token, and the answer never travels
 * <em>in</em> the token. Adding a "facilities" claim would couple token issuance
 * to Marshall, bloat the JWT, and leave stale linkage valid until the token
 * expires.
 *
 * <p>In production the key is the immutable Keycloak user id ({@code sub}). Here
 * it is the username, because the PoC's seed users get a fresh {@code sub} every
 * time the database volume is reset.
 */
@Component
public class FacilityDirectory {

    private static final Logger log = LoggerFactory.getLogger(FacilityDirectory.class);

    private final RestClient marshall;

    public FacilityDirectory(RestClient.Builder builder,
                             @Value("${poc.marshall.base-url}") String baseUrl) {
        // Timeouts are not optional on a call in the request path. Without them a
        // hung Marshall does not degrade this API, it exhausts its threads and
        // takes it down with it - the failure mode that turns one system's
        // outage into two.
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout(Duration.ofSeconds(2));
        requestFactory.setReadTimeout(Duration.ofSeconds(3));

        this.marshall = builder.baseUrl(baseUrl).requestFactory(requestFactory).build();
    }

    public List<Facility> findForUser(String username) {
        try {
            FacilityResponse response = marshall.get()
                    .uri("/facilities/{username}", username)
                    .retrieve()
                    .body(FacilityResponse.class);

            return response == null ? List.of() : response.facilities();
        }
        catch (RestClientException e) {
            // Do not fall back to an empty list. "Marshall is down" and "this user
            // has no facilities" are different answers, and conflating them shows
            // the user something false while hiding the outage.
            log.warn("Marshall lookup failed for {}: {}", username, e.getMessage());
            throw new BusinessSystemUnavailableException(
                    "Facility linkage is unavailable - the business system could not be reached", e);
        }
    }

    public record Facility(String reference, String holder, String limit, String status) {
    }

    private record FacilityResponse(String username, List<Facility> facilities) {
    }
}
