# Plesk Apache Watchdog

A small, local Bash watchdog for Plesk servers. It checks the primary hosted domains one by one and restarts `apache2` after three failed domain checks in the current complete domain-list pass.

All project documentation and files are written in English.

## Behavior

For every pass:

1. The watchdog obtains the domain list with `plesk bin site --list`.
2. The result of `plesk bin site --list` is used as-is as the domain list.
3. Domains are checked sequentially over HTTPS at `/`.
4. Each request appends `?health=<Unix timestamp>` and sends no-cache headers.
5. HTTP redirects are followed with `curl -L`. The final status code from 200 through 399 is considered successful.
6. The process waits 30 seconds before checking the next domain.
7. The global failure counter starts at zero at the beginning of every complete pass.
8. Each failed domain increments the global counter. Successful domains do not reset it.
9. The third failed domain in the same pass triggers one `systemctl restart apache2`.
10. The pass stops after that restart and the next pass starts with a zero counter.

Successful checks are not written to the event log. Restart attempts and results are written to `watchdog.log`.

## Important limitation

The `health` query parameter and `Cache-Control` headers reduce reuse of browser and proxy caches, but cannot guarantee that every application, CDN, reverse proxy, or server-side cache is bypassed. This watchdog checks the public root page; it does not prove that every PHP-FPM or database dependency is healthy.

Restarting Apache affects every hosted website on the server, not only the domain that triggered the restart.

## Requirements

- Linux server managed by Plesk.
- Apache service named `apache2`.
- Plesk CLI available as `plesk`.
- `curl`, `bash`, `systemctl`, and `flock`.
- Root access for installation and Apache restart.
- Plesk CLI output must be reviewed on the target server before production use.

## Install

Copy or clone this project onto the Plesk server, then run:

```bash
cd ~/repos/plesk-watchdog
sudo bash bin/install.sh
```

The installer:

- Verifies required commands and `apache2.service`.
- Installs the executable at `/usr/local/libexec/plesk-watchdog/plesk-watchdog`.
- Installs the systemd unit at `/etc/systemd/system/plesk-watchdog.service`.
- Installs configuration at `/etc/plesk-watchdog.conf` if it does not already exist.
- Creates the runtime directory and enables the service at boot.

The installer is safe to run again. An existing configuration file is preserved.

## Review the domain list before enabling production monitoring

Run these commands on the server:

```bash
plesk bin site --list
```

The watchdog expects the first whitespace-separated field of each output line to be the hostname. If the installed Plesk version uses a different format, update the discovery function before production use and add a regression test. No additional Plesk commands are used for filtering.

## Configuration

Edit `/etc/plesk-watchdog.conf`, then restart the service:

```bash
sudo editor /etc/plesk-watchdog.conf
sudo systemctl restart plesk-watchdog.service
```

Main settings:

| Setting | Default | Meaning |
|---|---:|---|
| `WATCHDOG_DELAY_SECONDS` | `30` | Delay between domain checks |
| `WATCHDOG_FAILURE_THRESHOLD` | `3` | Failed domains in one pass before restart |
| `WATCHDOG_RESTART_COOLDOWN_SECONDS` | `300` | Minimum time between restarts |
| `WATCHDOG_CONNECT_TIMEOUT_SECONDS` | `10` | Curl connection timeout |
| `WATCHDOG_REQUEST_TIMEOUT_SECONDS` | `30` | Curl total request timeout |
| `WATCHDOG_SCHEME` | `https` | URL scheme |
| `WATCHDOG_PATH` | `/` | URL path |
| `WATCHDOG_SUCCESS_MIN` | `200` | Lowest successful final HTTP status |
| `WATCHDOG_SUCCESS_MAX` | `399` | Highest successful final HTTP status |

The first version intentionally uses one global counter per pass, not a persistent counter per domain.

## Inspect the service

```bash
sudo systemctl status plesk-watchdog.service
sudo journalctl -u plesk-watchdog.service -f
sudo journalctl -u plesk-watchdog.service --since today
sudo tail -f /usr/local/libexec/plesk-watchdog/watchdog.log
```

Example event log line:

```text
2026-08-17T12:00:00+00:00 restart=success service=apache2 triggering_domain=example.com failures=3 last_domain=example.com
```

Only restart events are written to this file. `systemd` may still report service errors in the journal.

## Manual checks

Run the health request manually:

```bash
curl --silent --show-error --location \
  --connect-timeout 10 --max-time 30 \
  --header 'Cache-Control: no-cache, no-store, max-age=0' \
  --header 'Pragma: no-cache' \
  --output /dev/null --write-out '%{http_code}\n' \
  'https://example.com/?health='"$(date +%s)"
```

Run one controlled pass without installing the service:

```bash
WATCHDOG_DELAY_SECONDS=0 WATCHDOG_RESTART_COOLDOWN_SECONDS=0 \
  bash -c 'source bin/plesk-watchdog; load_config; validate_config; run_pass'
```

Do not use the controlled-pass command on a production server with intentionally failing domains unless an Apache restart is acceptable.

## Uninstall

Remove the service while preserving configuration and logs:

```bash
sudo bash bin/uninstall.sh
```

Remove the service, configuration, logs, and runtime files:

```bash
sudo bash bin/uninstall.sh --purge
```

## Testing

The tests use temporary fake `plesk`, `curl`, `systemctl`, and `sleep` commands. They do not restart the real Apache service.

```bash
bash tests/test_watchdog.sh
```

Before deployment, also perform a real-server validation on a non-critical Plesk host:

1. Confirm the domain list returned by `plesk bin site --list`.
2. Confirm every generated URL contains `?health=<timestamp>`.
3. Confirm successful requests do not appear in `watchdog.log`.
4. Create a controlled failure for three domains in one pass.
5. Confirm Apache restarts exactly once.
6. Confirm Apache becomes active again.
7. Confirm the event log contains the triggering and last checked domains.

## Security notes

The service runs as root because it must invoke the Plesk CLI and restart Apache. The installer uses a restrictive umask and file permissions. Do not place secrets in the configuration file. The health query parameter is not an authentication mechanism.
