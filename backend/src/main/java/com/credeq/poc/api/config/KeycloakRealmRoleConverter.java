package com.credeq.poc.api.config;

import java.util.Collection;
import java.util.List;
import java.util.Map;

import org.springframework.core.convert.converter.Converter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;

/**
 * Maps Keycloak's {@code realm_access.roles} onto Spring Security authorities.
 *
 * <p>Spring's default converter reads the {@code scope}/{@code scp} claim, which
 * carries OAuth scopes rather than realm roles, so without this a user with the
 * {@code facility-holder} role would arrive with no authorities at all.
 *
 * <p>Roles are prefixed with {@code ROLE_} so {@code hasRole('facility-holder')}
 * works in the controllers.
 */
public class KeycloakRealmRoleConverter implements Converter<Jwt, Collection<GrantedAuthority>> {

    private static final String REALM_ACCESS = "realm_access";
    private static final String ROLES = "roles";
    private static final String ROLE_PREFIX = "ROLE_";

    @Override
    @SuppressWarnings("unchecked")
    public Collection<GrantedAuthority> convert(Jwt jwt) {
        Map<String, Object> realmAccess = jwt.getClaimAsMap(REALM_ACCESS);
        if (realmAccess == null) {
            return List.of();
        }
        Object roles = realmAccess.get(ROLES);
        if (!(roles instanceof Collection<?> roleList)) {
            return List.of();
        }
        return ((Collection<String>) roleList).stream()
                .map(role -> (GrantedAuthority) new SimpleGrantedAuthority(ROLE_PREFIX + role))
                .toList();
    }
}
