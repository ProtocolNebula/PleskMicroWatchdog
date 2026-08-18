#!/usr/bin/env bash
# Install the Plesk Apache watchdog as a systemd service.
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/usr/local/libexec/plesk-watchdog"
CONFIG_FILE="/etc/plesk-watchdog.conf"
UNIT_FILE="/etc/systemd/system/plesk-watchdog.service"

[[ "$(id -u)" -eq 0 ]] || { printf 'Run this installer as root.\n' >&2; exit 1; }
for command_name in bash curl systemctl plesk; do
    command -v "$command_name" >/dev/null 2>&1 || { printf 'Required command not found: %s\n' "$command_name" >&2; exit 1; }
done
systemctl cat apache2.service >/dev/null 2>&1 || { printf 'Apache service apache2.service was not found.\n' >&2; exit 1; }

install -d -m 0750 "$INSTALL_DIR" "$INSTALL_DIR/state"
install -m 0750 "$PROJECT_DIR/bin/plesk-watchdog" "$INSTALL_DIR/plesk-watchdog"
install -m 0644 "$PROJECT_DIR/systemd/plesk-watchdog.service" "$UNIT_FILE"
if [[ ! -f "$CONFIG_FILE" ]]; then
    install -m 0600 "$PROJECT_DIR/config/plesk-watchdog.conf.example" "$CONFIG_FILE"
fi

systemctl daemon-reload
systemctl enable --now plesk-watchdog.service
systemctl is-active --quiet plesk-watchdog.service || {
    printf 'The service was installed but is not active.\n' >&2
    systemctl --no-pager --full status plesk-watchdog.service || true
    exit 1
}

printf 'Plesk Apache watchdog installed successfully.\n'
printf 'Service: systemctl status plesk-watchdog.service\n'
printf 'Logs:    journalctl -u plesk-watchdog.service\n'
printf 'Events:  %s/watchdog.log\n' "$INSTALL_DIR"
printf 'Config:  %s\n' "$CONFIG_FILE"
