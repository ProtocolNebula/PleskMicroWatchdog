#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

export WATCHDOG_CONFIG="$TEST_ROOT/watchdog.conf"
export WATCHDOG_LOG="$TEST_ROOT/watchdog.log"
export WATCHDOG_STATE_DIR="$TEST_ROOT/state"
export WATCHDOG_LOCK_FILE="$TEST_ROOT/watchdog.lock"
export WATCHDOG_DELAY_SECONDS=0
export WATCHDOG_FAILURE_THRESHOLD=3
export WATCHDOG_RESTART_COOLDOWN_SECONDS=0
export WATCHDOG_SCHEME="https"
export WATCHDOG_PATH="/"
export WATCHDOG_APACHE_SERVICE="apache2"
export WATCHDOG_DOMAIN_COMMAND="$TEST_ROOT/bin/plesk"

export WATCHDOG_CURL_COMMAND="$TEST_ROOT/bin/curl"
export WATCHDOG_SYSTEMCTL_COMMAND="$TEST_ROOT/bin/systemctl"
export WATCHDOG_SLEEP_COMMAND="$TEST_ROOT/bin/sleep"

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state"
cat > "$WATCHDOG_CONFIG" <<EOF
WATCHDOG_LOG=$WATCHDOG_LOG
WATCHDOG_STATE_DIR=$WATCHDOG_STATE_DIR
WATCHDOG_LOCK_FILE=$WATCHDOG_LOCK_FILE
WATCHDOG_DELAY_SECONDS=0
WATCHDOG_FAILURE_THRESHOLD=3
WATCHDOG_RESTART_COOLDOWN_SECONDS=0
WATCHDOG_SCHEME=https
WATCHDOG_PATH=/
WATCHDOG_APACHE_SERVICE=apache2
WATCHDOG_DOMAIN_COMMAND=$WATCHDOG_DOMAIN_COMMAND

WATCHDOG_CURL_COMMAND=$WATCHDOG_CURL_COMMAND
WATCHDOG_SYSTEMCTL_COMMAND=$WATCHDOG_SYSTEMCTL_COMMAND
WATCHDOG_SLEEP_COMMAND=$WATCHDOG_SLEEP_COMMAND
EOF

cat > "$WATCHDOG_DOMAIN_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'example.com' 'blog.example.com' 'alias.example.net'
EOF


cat > "$WATCHDOG_SLEEP_COMMAND" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$TEST_ROOT/bin/"*

# Production file is intentionally absent during the RED phase.
source "$PROJECT_ROOT/bin/plesk-watchdog"

assert_equal() {
    local expected="$1" actual="$2" message="$3"
    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s (expected=%q actual=%q)\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

run_test() {
    local name="$1"
    printf 'TEST: %s\n' "$name"
    "$name"
    printf 'PASS: %s\n' "$name"
}

test_domain_discovery_uses_site_list_only() {
    local domains
    domains="$(discover_domains)"
    assert_equal $'example.com\nblog.example.com\nalias.example.net' "$domains" 'site list is the only domain source'
}

test_health_check_adds_timestamp_query_and_accepts_redirect() {
    cat > "$WATCHDOG_CURL_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$TEST_ROOT/curl-args"
printf '302\n'
EOF
    chmod +x "$WATCHDOG_CURL_COMMAND"
    export TEST_ROOT
    health_check 'example.com'
    grep -Eq -- '--location| -L' "$TEST_ROOT/curl-args"
    grep -Eq -- '--insecure| -k' "$TEST_ROOT/curl-args"
    grep -Eq 'health=[0-9]+' "$TEST_ROOT/curl-args"
}

test_failed_health_check_reports_curl_diagnostic() {
    cat > "$WATCHDOG_CURL_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf 'curl: (6) Could not resolve host\n' >&2
exit 6
EOF
    chmod +x "$WATCHDOG_CURL_COMMAND"
    local diagnostic
    diagnostic="$(health_check 'broken.example.com' 2>&1 || true)"
    [[ "$diagnostic" == *'health_check_failed domain=broken.example.com'* ]] || {
        printf 'FAIL: failed health checks expose diagnostics (actual=%q)\n' "$diagnostic" >&2
        exit 1
    }
}

test_http_503_is_accepted_for_inactive_plesk_sites() {
    cat > "$WATCHDOG_CURL_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '503\n'
EOF
    chmod +x "$WATCHDOG_CURL_COMMAND"
    health_check 'inactive.example.com'
}

test_third_failure_restarts_once_per_pass() {
    cat > "$WATCHDOG_DOMAIN_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'one.example.com' 'two.example.com' 'three.example.com' 'four.example.com'
EOF
    cat > "$WATCHDOG_CURL_COMMAND" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    cat > "$WATCHDOG_SYSTEMCTL_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/systemctl-calls"
if [[ "$1" == 'is-active' ]]; then exit 0; fi
exit 0
EOF
    chmod +x "$WATCHDOG_DOMAIN_COMMAND" "$WATCHDOG_CURL_COMMAND" "$WATCHDOG_SYSTEMCTL_COMMAND"
    export TEST_ROOT
    run_pass
    local restarts
    restarts="$(grep -c -- 'restart apache2' "$TEST_ROOT/systemctl-calls" || true)"
    assert_equal '1' "$restarts" 'only one restart occurs in a pass'
}

test_success_does_not_reset_global_counter() {
    cat > "$WATCHDOG_DOMAIN_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'one.example.com' 'two.example.com' 'three.example.com'
EOF
    cat > "$WATCHDOG_CURL_COMMAND" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'one.example.com'* || "$*" == *'two.example.com'* ]]; then exit 1; fi
printf '200\n'
EOF
    cat > "$WATCHDOG_SYSTEMCTL_COMMAND" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_ROOT/systemctl-calls"
exit 0
EOF
    : > "$TEST_ROOT/systemctl-calls"
    chmod +x "$WATCHDOG_DOMAIN_COMMAND" "$WATCHDOG_CURL_COMMAND" "$WATCHDOG_SYSTEMCTL_COMMAND"
    export TEST_ROOT
    run_pass
    local restarts
    restarts="$(grep -c -- 'restart apache2' "$TEST_ROOT/systemctl-calls" || true)"
    assert_equal '0' "$restarts" 'a successful domain does not hide previous failures'
}

run_test test_domain_discovery_uses_site_list_only
run_test test_health_check_adds_timestamp_query_and_accepts_redirect
run_test test_failed_health_check_reports_curl_diagnostic
run_test test_http_503_is_accepted_for_inactive_plesk_sites
run_test test_third_failure_restarts_once_per_pass
run_test test_success_does_not_reset_global_counter
printf 'All tests passed.\n'
