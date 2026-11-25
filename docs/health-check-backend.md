# Health-check ping backend

This dead-man backend works with Healthchecks.io-compatible ping URLs. It sends
`/start`, success, and `/fail` pings with a unique `rid` query parameter. It is
registered before chat backends, uses HTTPS only, and a ping failure never
changes the update run result.

Configure one secret and leave it blank to disable the backend:

- `HEALTHCHECK_PING_URL`: base ping URL, for example
  `https://example.invalid/ping/00000000-0000-0000-0000-000000000000`.
- `LOCAL_HEALTHCHECK_PING_URL`: setup input written to the root-only secrets file.
- `DOPPLER_HEALTHCHECK_SECRET`: Doppler name override. Default:
  `UPDATE_NOTIFIER_HEALTHCHECK_PING_URL`.

The URL is passed through a mode-600 curl configuration file, not process
arguments or logs. Failure text is flattened and limited to 1024 characters.
