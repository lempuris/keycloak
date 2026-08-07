package com.credeq.poc.api.config;

import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;

/**
 * Rejects tokens that were not minted for this API.
 *
 * <p>Without this check the API would accept any valid token from the realm,
 * including one issued to a different client for a different purpose. The
 * {@code aud} claim is put there by the {@code guarantee-gateway-api-audience}
 * client scope in the realm configuration.
 */
public class AudienceValidator implements OAuth2TokenValidator<Jwt> {

    private final String requiredAudience;

    public AudienceValidator(String requiredAudience) {
        this.requiredAudience = requiredAudience;
    }

    @Override
    public OAuth2TokenValidatorResult validate(Jwt token) {
        if (token.getAudience() != null && token.getAudience().contains(requiredAudience)) {
            return OAuth2TokenValidatorResult.success();
        }
        return OAuth2TokenValidatorResult.failure(new OAuth2Error(
                "invalid_token",
                "Required audience '" + requiredAudience + "' not present in token",
                "https://tools.ietf.org/html/rfc6750#section-3.1"));
    }
}
