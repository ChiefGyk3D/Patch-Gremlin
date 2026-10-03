# Security Policy

## Supported Versions

| Version | Supported                   |
| ------- | --------------------------- |
| 2.x     | ✅                          |
| 1.x     | ❌ — see the advisory below |

## Reporting a Vulnerability

Please report security issues privately via
[GitHub Security Advisories](https://github.com/ChiefGyk3D/Patch-Gremlin/security/advisories/new)
rather than opening a public issue.

Include the affected version, your OS and package manager, and reproduction
steps. Expect an initial response within 7 days.

## Advisory: credential exposure in 1.x

Versions before 2.0.0 wrote the Doppler service token into two
world-readable (mode 0644) files:

- `/etc/systemd/system/update-notifier.service`
- `/etc/apt/apt.conf.d/99patch-gremlin-notification`

`systemctl show update-notifier.service` also exposed it to unprivileged
users. Any local user could read a token granting access to the whole Doppler
config.

Additionally, `config.sh` was sourced as root after a filter that only
*warned* about command substitution, so `export X="$(cmd)"` executed —
a pattern the shipped `config.example.sh` recommended.

**If you ran 1.x with Doppler:**

1. Rotate the service token in the Doppler dashboard.
2. Upgrade and re-run the installer — it removes the legacy hook and moves
   secrets into `/etc/update-notifier/env` (mode 600).
3. Confirm nothing is left behind:

   ```bash
   sudo grep -rl 'dp\.st\.' /etc/systemd/system /etc/apt/apt.conf.d || \
     echo "clean"
   ```

## How secrets are handled in 2.x

- Secrets live in `/etc/update-notifier/env` or
  `/etc/update-notifier/secrets.conf`, both mode 600 and root-owned, loaded
  via systemd `EnvironmentFile=`.
- The notifier refuses to source a config or secrets file that is
  group/world-writable or not owned by root.
- `config.sh` is parsed against an allowlist and never evaluated; values
  containing shell metacharacters are rejected.
- Log content is JSON-escaped through a single code path before being placed
  in any payload.
- Errors are logged with token-shaped strings redacted.
- The systemd unit runs with `NoNewPrivileges`, `ProtectSystem=strict`,
  `ProtectHome`, `PrivateTmp` and related restrictions.

`test-deployment.sh` and the CI suite both assert that no world-readable file
contains a Doppler token.
