package com.credeq.poc.api.facility;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ResponseStatus;

/**
 * Marshall could not be reached, so facility linkage is unknown.
 *
 * <p>Deliberately a 503 and not an empty list. An empty list is a real answer —
 * a newly provisioned broker genuinely has no facilities yet — so returning one
 * on failure would tell the user something false and hide the outage from
 * monitoring. "I don't know" and "none" are different answers.
 *
 * <p>Note what still works while this is being thrown: logging in, and every
 * endpoint that only needs identity. That is the Marshall pivot doing its job —
 * Marshall is on the data path, never the login path.
 */
@ResponseStatus(HttpStatus.SERVICE_UNAVAILABLE)
public class BusinessSystemUnavailableException extends RuntimeException {

    public BusinessSystemUnavailableException(String message, Throwable cause) {
        super(message, cause);
    }
}
