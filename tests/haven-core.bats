#!/usr/bin/env bats
# Unit tests for the Docker-free core functions of ./haven.
# Run from the repository root:  bats tests/
#

setup() {
  TEST_DIR="$(mktemp -d)"
  ROOT_DIR="$TEST_DIR"
  export LC_CTYPE="${LC_CTYPE:-en_US.UTF-8}"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# ---------- validate_env_value ----------

@test "validate_env_value: valid port passes and normalizes" {
  run bash -c 'source haven; set +e; validate_env_value RELAY_PORT 3355; echo "rc=$? val=$VALIDATION_VALUE err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0 val=3355 err="* ]]
}

@test "validate_env_value: out-of-range port is rejected" {
  run bash -c 'source haven; set +e; validate_env_value RELAY_PORT 70000; echo "rc=$? err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"Port must be 1-65535."* ]]
}

@test "validate_env_value: mixed-case npub is rejected" {
  run bash -c 'source haven; set +e; validate_env_value OWNER_NPUB npub1ABCdef; echo "rc=$? err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"lowercase"* ]]
}

@test "validate_env_value: uppercase npub is normalized to lowercase" {
  run bash -c 'source haven; set +e; validate_env_value OWNER_NPUB NPUB1AC234DEF; echo "rc=$? val=$VALIDATION_VALUE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0 val=npub1ac234def"* ]]
}

@test "validate_env_value: WOT_REFRESH_INTERVAL accepts duration syntax (regression: used to hit the *_INTERVAL is_int branch)" {
  run bash -c 'source haven; set +e; validate_env_value WOT_REFRESH_INTERVAL 24h; echo "rc=$? err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "validate_env_value: WOT_REFRESH_INTERVAL rejects garbage with the duration message" {
  run bash -c 'source haven; set +e; validate_env_value WOT_REFRESH_INTERVAL banana; echo "rc=$? err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"must look like 24h, 30m, or 10s"* ]]
}

@test "validate_env_value: BACKUP_INTERVAL_HOURS gets its own error message" {
  run bash -c 'source haven; set +e; validate_env_value BACKUP_INTERVAL_HOURS abc; echo "rc=$? err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"BACKUP_INTERVAL_HOURS must be a number"* ]]
}

@test "validate_env_value: numeric timeout passes via the is_int catch-all" {
  run bash -c 'source haven; set +e; validate_env_value BLASTR_TIMEOUT_SECONDS 5; echo "rc=$? val=$VALIDATION_VALUE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0 val=5"* ]]
}

@test "validate_env_value: log level is uppercased" {
  run bash -c 'source haven; set +e; validate_env_value HAVEN_LOG_LEVEL debug; echo "rc=$? val=$VALIDATION_VALUE"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0 val=DEBUG"* ]]
}

@test "validate_env_value: unquoted spaces are rejected" {
  run bash -c 'source haven; set +e; validate_env_value RELAY_NAME "my relay"; echo "rc=$? err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
  [[ "$output" == *"must be quoted"* ]]
}

# ---------- log_sanitize_line ----------

@test "log_sanitize_line: strips ANSI color sequences" {
  run bash -c 'source haven; set +e; log_sanitize_line "$(printf "\033[31mfoo\033[0m bar")"; printf "[%s]" "$_SANITIZED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[foo bar]"* ]]
}

@test "log_sanitize_line: removes carriage returns and expands tabs" {
  run bash -c 'source haven; set +e; log_sanitize_line "$(printf "a\r\tb")"; printf "[%s]" "$_SANITIZED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[a  b]"* ]]
}

@test "log_sanitize_line: plain ASCII passes through unchanged" {
  run bash -c 'source haven; set +e; log_sanitize_line "hello world"; printf "[%s]" "$_SANITIZED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[hello world]"* ]]
}

@test "log_sanitize_line: multi-digit and semicolon CSI parameters are stripped" {
  run bash -c 'source haven; set +e; log_sanitize_line "$(printf "\033[38;5;203mx\033[1;2H y")"; printf "[%s]" "$_SANITIZED"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[x y]"* ]]
}

# ---------- tui_truncate ----------

@test "tui_truncate: short string passes through unchanged" {
  run bash -c 'source haven; set +e; tui_truncate "abc" 10; printf "[%s]" "$_TRUNC"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[abc]"* ]]
}

@test "tui_truncate: long string is cut and ends with ellipsis" {
  run bash -c 'source haven; set +e; tui_truncate "0123456789ABCDEF" 10; printf "[%s]" "$_TRUNC"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[0123456...]"* ]]
}

# NOTE: pins the current codepoint-counting behavior for wide characters.
# Phase P3 of docs/plans/2026-09-20T1356-tui-stabilitaet-qol.md switches
# tui_truncate to display width — update this test together with that change.
@test "tui_truncate: CJK string truncates with ellipsis (P3: revisit for display width)" {
  # Locale-robust: under a UTF-8 locale 3 codepoints survive, under C the
  # first multibyte char — either way the tail is cut and the ellipsis added.
  run bash -c 'source haven; set +e; tui_truncate "こんにちは世界" 6; printf "[%s]" "$_TRUNC"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"..."* ]]
  [[ "$output" != *"世界"* ]]
}

# ---------- read_env_var / set_env_var ----------

@test "set_env_var then read_env_var round-trips a new key" {
  run bash -c 'source haven; set +e; ROOT_DIR="$(mktemp -d)"; set_env_var RELAY_URL relay.example.com; read_env_var RELAY_URL; echo "rc=$?"; rm -rf "$ROOT_DIR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"relay.example.com"* ]]
}

@test "set_env_var overwrites an existing key in place and keeps other lines" {
  run bash -c 'source haven; set +e; ROOT_DIR="$(mktemp -d)"; printf "A=1\nRELAY_URL=old\nB=2\n" > "$ROOT_DIR/.env"; set_env_var RELAY_URL new; printf "A=%s RELAY=%s B=%s\n" "$(read_env_var A)" "$(read_env_var RELAY_URL)" "$(read_env_var B)"; rm -rf "$ROOT_DIR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"A=1 RELAY=new B=2"* ]]
}

@test "set_env_var creates a .bak backup before modifying an existing .env" {
  run bash -c 'source haven; set +e; ROOT_DIR="$(mktemp -d)"; printf "K=v\n" > "$ROOT_DIR/.env"; set_env_var K w; test -f "$ROOT_DIR/.env.bak" && echo backup-ok; rm -rf "$ROOT_DIR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"backup-ok"* ]]
}

@test "read_env_var strips inline comments and quotes" {
  run bash -c 'source haven; set +e; ROOT_DIR="$(mktemp -d)"; printf "RELAY_NAME=\"my relay\" # the name\n" > "$ROOT_DIR/.env"; read_env_var RELAY_NAME; echo "rc=$?"; rm -rf "$ROOT_DIR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
  [[ "$output" == *"my relay"* ]]
}

@test "read_env_var fails cleanly when .env is missing" {
  run bash -c 'source haven; set +e; ROOT_DIR="$(mktemp -d)"; read_env_var NOPE; echo "rc=$?"; rm -rf "$ROOT_DIR"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=1"* ]]
}
