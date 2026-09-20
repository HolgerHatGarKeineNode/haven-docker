#!/usr/bin/env bats
# Unit tests for the P4 input QoL in ./haven: menu navigation keys, digit
# shortcuts, value masking, and the inline prompt validators.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

nav_setup() {
  MENU_IDS=(one two three four five six seven eight nine ten)
  TUI_SEL=0
  TUI_VISIBLE_ROWS=4
  TUI_NEED_LEFT=0
}

@test "tui_handle_key: j and k move the selection like down/up" {
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e
    MENU_IDS=(one two three four five); TUI_SEL=0; TUI_NEED_LEFT=0
    tui_handle_key j; a=$TUI_SEL
    tui_handle_key j; b=$TUI_SEL
    tui_handle_key k; c=$TUI_SEL
    tui_handle_key k; d=$TUI_SEL
    echo "sel=$a,$b,$c,$d"'
  [ "$status" -eq 0 ]
  [[ "$output" == "sel=1,2,1,0" ]]
}

@test "tui_handle_key: g and G jump to the first and last entry" {
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e
    MENU_IDS=(one two three four five); TUI_SEL=2; TUI_NEED_LEFT=0
    tui_handle_key G; a=$TUI_SEL
    tui_handle_key g; b=$TUI_SEL
    echo "sel=$a,$b"'
  [ "$status" -eq 0 ]
  [[ "$output" == "sel=4,0" ]]
}

@test "tui_handle_key: home and end jump like g and G" {
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e
    MENU_IDS=(one two three four five); TUI_SEL=2; TUI_NEED_LEFT=0
    tui_handle_key end; a=$TUI_SEL
    tui_handle_key home; b=$TUI_SEL
    echo "sel=$a,$b"'
  [ "$status" -eq 0 ]
  [[ "$output" == "sel=4,0" ]]
}

# NOTE: PgUp/PgDn paged the menu until P4; the P5 DoD assigns them to the
# log panel's scrollback. Their new behavior is covered in
# tests/haven-panel.bats (page-key scroll, no-op in status mode).

@test "tui_handle_key: digit shortcuts select the nth entry directly" {
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e
    MENU_IDS=(one two three four five six seven eight nine ten); TUI_SEL=0; TUI_NEED_LEFT=0
    tui_handle_key 3; a=$TUI_SEL
    tui_handle_key 9; b=$TUI_SEL
    echo "sel=$a,$b"'
  [ "$status" -eq 0 ]
  [[ "$output" == "sel=2,8" ]]
}

@test "tui_handle_key: digit beyond the menu is a no-op" {
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e
    MENU_IDS=(one two three); TUI_SEL=0; TUI_NEED_LEFT=0
    tui_handle_key 9; echo "sel=$TUI_SEL needleft=$TUI_NEED_LEFT"'
  [ "$status" -eq 0 ]
  [[ "$output" == "sel=0 needleft=0" ]]
}

# ---------- masking ----------

@test "mask_env_value: long values show the ellipsis plus the last four" {
  run bash -c 'source '"$REPO_ROOT"'/haven; mask_env_value "abcdefgh1234"; echo "m=$_MASKED"'
  [ "$status" -eq 0 ]
  [[ "$output" == "m=…1234" ]]
}

@test "mask_env_value: short and empty values" {
  run bash -c 'source '"$REPO_ROOT"'/haven; mask_env_value "abc"; a=$_MASKED; mask_env_value ""; b=$_MASKED; echo "m=[$a][$b]"'
  [ "$status" -eq 0 ]
  [[ "$output" == "m=[…][]" ]]
}

@test "env_key_is_sensitive: KEY/SECRET/PASSWORD/TOKEN match, others do not" {
  run bash -c 'source '"$REPO_ROOT"'/haven; set +e
    a=0; env_key_is_sensitive S3_SECRET_KEY && a=1
    b=0; env_key_is_sensitive S3_ACCESS_KEY_ID && b=1
    c=0; env_key_is_sensitive BACKUP_PASSWORD && c=1
    d=0; env_key_is_sensitive AUTH_TOKEN && d=1
    e=0; env_key_is_sensitive RELAY_URL || e=1
    f=0; env_key_is_sensitive OWNER_NPUB || f=1
    echo "s=$a$b$c$d$e$f"'
  [ "$status" -eq 0 ]
  [[ "$output" == "s=111111" ]]
}

# ---------- inline validators ----------

@test "validator: new key rejects bad format and duplicates, accepts fresh keys" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR="$(mktemp -d)"
    _validate_prompt_new_key "1bad"; r1=$?
    _validate_prompt_new_key "GOOD_KEY_2"; r2=$?
    printf "GOOD_KEY_2=x\n" > "$ROOT_DIR/.env"
    _validate_prompt_new_key "GOOD_KEY_2"; r3=$?
    rm -rf "$ROOT_DIR"
    echo "r=$r1,$r2,$r3 err=$VALIDATION_ERROR"'
  [ "$status" -eq 0 ]
  [[ "$output" == "r=1,0,1"* ]]
}

@test "validator: env value rejects invalid port inline with the message" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    PROMPT_ENV_KEY=RELAY_PORT
    _validate_prompt_env_value "70000"; r1=$?
    e1="$VALIDATION_ERROR"
    _validate_prompt_env_value "3355"; r2=$?
    p="$PROMPT_RESULT"
    echo "r=$r1,$r2 err=$e1 result=$p"'
  [ "$status" -eq 0 ]
  [[ "$output" == "r=1,0 err=Port must be 1-65535. result=3355" ]]
}

@test "validator: npub value gets normalized through PROMPT_RESULT" {
  run bash -c '
    source '"$REPO_ROOT"'/haven
    set +e
    PROMPT_ENV_KEY=OWNER_NPUB
    _validate_prompt_env_value "npub1ac234def"; r=$?
    echo "r=$r result=$PROMPT_RESULT"'
  [ "$status" -eq 0 ]
  [[ "$output" == "r=0 result=npub1ac234def" ]]
}
