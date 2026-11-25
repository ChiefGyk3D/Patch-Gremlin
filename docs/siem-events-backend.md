# SIEM events backend

Set `ENABLE_EVENTS=true` to append one schema-1 JSON object per notifier run.
`EVENTS_FILE` defaults to `/var/log/patch-gremlin/events.jsonl`, and
`EVENTS_MAX_BYTES` defaults to `1048576`. At the cap, the current file moves
to `.1` before the next event is written.

Each object has stable keys: `schema`, `timestamp`, `host`, `status`,
`upgraded_count`, `security_count`, `held_back_count`, `reboot_required`,
`duration`, and `run_id`. The same fields are sent once through
`logger -t patch-gremlin`. Events never include notification credentials or
URLs.

Direct notifier configuration uses `PATCH_GREMLIN_EVENTS_FILE` and
`PATCH_GREMLIN_EVENTS_MAX_BYTES`; an empty file setting disables events.

