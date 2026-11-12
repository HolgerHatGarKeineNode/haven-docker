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
  [[ "$output" == *"A duration above zero in h, m and s, e.g. 24h, 90m or 1h30m."* ]]
}

# Upstream v1.2.2, main.go getLogLevelFromConfig: case "DEBUG", "INFO", "WARN",
# "ERROR", default slog.LevelInfo — WARN is a level, WARNING is not.
@test "validate_env_value: HAVEN_LOG_LEVEL accepts WARN (upstream's level) and refuses WARNING with a message naming WARN" {
  run bash -c 'source haven; set +e
    for v in WARN warn DEBUG INFO ERROR; do validate_env_value HAVEN_LOG_LEVEL "$v"; echo "$v rc=$? val=$VALIDATION_VALUE"; done
    validate_env_value HAVEN_LOG_LEVEL WARNING; echo "WARNING rc=$? err=$VALIDATION_ERROR"
    validate_env_value HAVEN_LOG_LEVEL TRACE; echo "TRACE rc=$? err=$VALIDATION_ERROR"
    env_rule_text HAVEN_LOG_LEVEL; echo "rule=$_RULE"'
  echo "$output"
  [[ "$output" == *"WARN rc=0 val=WARN"* ]]
  [[ "$output" == *"warn rc=0 val=WARN"* ]]
  [[ "$output" == *"ERROR rc=0 val=ERROR"* ]]
  [[ "$output" == *"WARNING rc=1 err=Haven reads WARN, not WARNING (WARNING logs at INFO). Type WARN."* ]]
  [[ "$output" == *"TRACE rc=1 err=HAVEN_LOG_LEVEL must be DEBUG, INFO, WARN or ERROR."* ]]
  [[ "$output" == *"rule=DEBUG, INFO, WARN or ERROR."* ]]
}

@test "settings details: a stored WARNING (or lower-case level) is said to log at INFO; WARN is not flagged" {
  run bash -c 'source haven; set +e
    for v in "\"WARNING\"" warn WARN "\"INFO\""; do env_stored_value_note HAVEN_LOG_LEVEL "$v"; echo "$v: [$_STORED_NOTE]"; done'
  echo "$output"
  [[ "$output" == *'"WARNING": [Haven does not know WARNING and logs at INFO; WARN is its warnings level.]'* ]]
  [[ "$output" == *'warn: [Haven does not know warn and logs at INFO'* ]]
  [[ "$output" == *'WARN: []'* ]]
  [[ "$output" == *'"INFO": []'* ]]
}

# Upstream v1.2.2, config.go getEnvDuration: time.ParseDuration(value), panic
# on error — Go has no day unit; pkg/wot PeriodicRefresh: time.NewTicker(interval),
# which panics on a duration of zero.
@test "validate_env_value: WOT_REFRESH_INTERVAL refuses days with a message naming h, m, s; refuses zero; takes Go durations" {
  run bash -c 'source haven; set +e
    for v in 24h 90m 10s 1h30m; do validate_env_value WOT_REFRESH_INTERVAL "$v"; echo "$v rc=$?"; done
    for v in 1d 7d 0h 0m0s; do validate_env_value WOT_REFRESH_INTERVAL "$v"; echo "$v rc=$? err=$VALIDATION_ERROR"; done
    env_rule_text WOT_REFRESH_INTERVAL; echo "rule=$_RULE"
    env_stored_value_note WOT_REFRESH_INTERVAL "\"1d\""; echo "note=$_STORED_NOTE"'
  echo "$output"
  [[ "$output" == *"24h rc=0"* && "$output" == *"90m rc=0"* && "$output" == *"10s rc=0"* && "$output" == *"1h30m rc=0"* ]]
  [[ "$output" == *"1d rc=1 err=Haven has no day unit: use hours (1d = 24h). Units: h, m, s."* ]]
  [[ "$output" == *"7d rc=1 err=Haven has no day unit: use hours (7d = 168h). Units: h, m, s."* ]]
  [[ "$output" == *"0h rc=1 err=A duration above zero"* ]]
  [[ "$output" == *"0m0s rc=1 err=A duration above zero"* ]]
  [[ "$output" == *"rule=A duration above zero in hours, minutes and seconds (h, m, s), e.g. 24h, 90m or 1h30m. No days: 1d is 24h."* ]]
  [[ "$output" == *"note=Haven cannot read 1d as a duration and stops at start"* ]]
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
@test "tui_truncate: CJK string truncates with ellipsis" {
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

@test "set_env_var creates a timestamped .bak backup before modifying an existing .env" {
  run bash -c 'source haven; set +e; ROOT_DIR="$(mktemp -d)"; printf "K=v\n" > "$ROOT_DIR/.env"; set_env_var K w; ls -1A "$ROOT_DIR" | grep -c "^\.env\.bak\.[0-9]\{14\}$"; rm -rf "$ROOT_DIR"'
  [ "$status" -eq 0 ]
  [[ "$output" == "1" ]]
}

@test "backup_config_file: keeps only the 10 most recent backups" {
  run bash -c '
    source haven
    set +e
    ROOT_DIR="$(mktemp -d)"
    f="$ROOT_DIR/x.conf"
    printf "v0\n" > "$f"
    # twelve pre-dated backups, sortable by name
    for ((i=1; i<=12; i++)); do
      cp "$f" "$(printf "%s.bak.20260101%02d0000" "$f" "$i")"
    done
    backup_config_file "$f"
    n=$(ls -1 "$f".bak.* 2>/dev/null | wc -l)
    rm -rf "$ROOT_DIR"
    echo "backups=$n"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "backups=10"* ]]
}

@test "json_write_tmp backs up the json file before replacing it" {
  run bash -c '
    source haven
    set +e
    ROOT_DIR="$(mktemp -d)"
    f="$ROOT_DIR/list.json"
    printf "[]\n" > "$f"
    printf "[\"a\"]\n" | json_write_tmp "$f"
    found=$(ls -1 "$f".bak.* 2>/dev/null | wc -l)
    content=$(cat "$f")
    rm -rf "$ROOT_DIR"
    echo "backups=$found"
    echo "content=$content"
  '
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "backups=1" ]]
  [[ "${lines[1]}" == 'content=["a"]' ]]
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

@test "warn_missing_critical_env names the missing keys on a stripped .env" {
  run bash -c '
    source haven
    set +e
    ROOT_DIR="$(mktemp -d)"
    printf "DOCKER_UID=1000\nDOCKER_GID=100\n" > "$ROOT_DIR/.env"
    out="$(warn_missing_critical_env 2>&1)"
    rm -rf "$ROOT_DIR"
    echo "$out" | grep -o "OWNER_NPUB RELAY_URL RELAY_PORT" | head -1
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "OWNER_NPUB RELAY_URL RELAY_PORT" ]]
}

@test "warn_missing_critical_env stays silent on a complete .env" {
  run bash -c '
    source haven
    set +e
    ROOT_DIR="$(mktemp -d)"
    { echo "OWNER_NPUB=npub1abc234def"; echo "RELAY_URL=relay.example.com"; echo "RELAY_PORT=3355";
      echo "PRIVATE_RELAY_NPUB=npub1abc234def"; echo "CHAT_RELAY_NPUB=npub1abc234def";
      echo "OUTBOX_RELAY_NPUB=npub1abc234def"; echo "INBOX_RELAY_NPUB=npub1abc234def"; } > "$ROOT_DIR/.env"
    out="$(warn_missing_critical_env 2>&1)"
    rm -rf "$ROOT_DIR"
    echo "lines=$(printf "%s" "$out" | grep -c . || true)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == "lines=0" ]]
}
