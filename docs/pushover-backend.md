# Pushover break-glass backend

Pushover sends only when the update run status is `error`. Routine update and
no-update reports never use this backend. Requests go to the fixed HTTPS
Pushover messages endpoint and are not retried after an HTTP 4xx response.

Exact secrets-file or environment keys:

- `PUSHOVER_TOKEN` and `PUSHOVER_USER`: required together.
- `PUSHOVER_PRIORITY`: `0` by default, or `2` for emergency delivery.
- `PUSHOVER_RETRY`: required retry interval for priority 2, default `60`.
- `PUSHOVER_EXPIRE`: required expiry for priority 2, default `3600`.

Setup inputs use the `LOCAL_` prefix. Doppler name overrides are
`DOPPLER_PUSHOVER_TOKEN_SECRET` and `DOPPLER_PUSHOVER_USER_SECRET`. Messages
are limited to 1024 characters. Credentials are form encoded in a payload
file and never appear in curl arguments or logs.

