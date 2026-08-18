#!/usr/bin/env bash
# Remove the Plesk Apache watchdog systemd service.
set -Eeuo pipefail

INSTALL_DIR="/usr/local/libexec/plesk-watchdog"
CONFIG_FILE="/etc/plesk-watchdog.conf"
UNIT_FILE="/etc/systemd/system/plesk-watchdog.service"
PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1
[[ "$(id -u)" -eq 0 ]] || { printf 'Run this uninstaller as root.\n' >&2; exit 1; }

systemctl disable --now plesk-watchdog.service 2>/dev/null || true
rm -f "$UNIT_FILE"
systemctl daemon-reload

if (( PURGE == 1 )); then
    rm -f "$CONFIG_FILE"
    rm -rf "$INSTALL_DIR"
    printf 'Watchdog removed, including its configuration and logs.\n'
else
    printf 'Watchdog service and unit removed.\n'
    printf 'Configuration and logs were preserved at %s and %s.\n' "$CONFIG_FILE" "$INSTALL_DIR"
    printf 'Use --purge to remove them.\n'
fi
