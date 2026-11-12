#!/usr/bin/env bats
# The settings editor: sections and descriptions come from .env.example (one
# source), rows are "label  value" with the label cut in the middle, the right
# pane shows the selected setting's details, "/" filters on name and
# description. Also .env.example itself: key list and example values as in
# 091d9c8, env-upgrade unchanged.
# Run from the repository root:  bats tests/

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
EMU="$REPO_ROOT/tests/term-emu.py"
LONGEST=PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL
CANARY="CANARY-7f3a9c-SECRET-VALUE-0042"

setup() {
  command -v python3 >/dev/null 2>&1 || skip "python3 missing (emulator and parser)"
  TEST_DIR="$(mktemp -d)"
  SB="$TEST_DIR/sb"
  mkdir -p "$SB/db"
  cp "$REPO_ROOT/.env.example" "$SB/.env.example"
  cp "$REPO_ROOT/.env.example" "$SB/.env"
}

teardown() {
  [[ -n "${TEST_DIR:-}" ]] && rm -rf "$TEST_DIR"
}

# in_haven <snippet> — ./haven sourced, ROOT_DIR = the sandbox, docker offline,
# size COLS x ROWS (80x24), the settings list open
in_haven() {
  SNIP="$1" S="$SB" bash -c '
    export TERM=xterm-256color COLUMNS="${COLS:-80}" LINES="${ROWS:-24}"
    source '"$REPO_ROOT"'/haven
    set +e
    ROOT_DIR="$S" BACKUP_DIR="$S/backups" SCRIPT_NAME=haven
    TUI_DOCKER_OK=0 LOG_LINES=()
    docker() { return 1; }
    tui_update_layout
    tui_set_view env_list
    tui_build_menu; TUI_NEED_MENU=0
    eval "$SNIP"
  '
}

# example_parse <file> — "key<TAB>section<TAB>description" per active key,
# parsed independently of ./haven: "## " opens a section, the "# " lines
# directly above a key are its description
example_parse() {
  python3 -I - "$1" <<'PY'
import re, sys
sec, pend = "General", []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if line.startswith("## "):
        sec, pend = line[3:].strip(), []
    elif re.match(r"^#\s*$", line) or not line.strip():
        pend = []
    elif re.match(r"^# ?[A-Za-z_][A-Za-z0-9_]*=", line):
        pend = []
    elif line.startswith("#"):
        pend.append(re.sub(r"^#\s?", "", line))
    else:
        m = re.match(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=", line)
        if m:
            print("%s\t%s\t%s" % (m.group(1), sec, " ".join(pend)))
        pend = []
PY
}

# value_parse <file> — "key=value" (value as written, trailing comment cut)
value_parse() {
  python3 -I - "$1" <<'PY'
import re, sys
for line in open(sys.argv[1], encoding="utf-8"):
    m = re.match(r'^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$', line.rstrip("\n"))
    if not m: continue
    q, out = "", ""
    for c in m.group(2):
        if c in "\"'": q = "" if q == c else (c if q == "" else q)
        if c == "#" and q == "": break
        out += c
    print("%s=%s" % (m.group(1), out.rstrip()))
PY
}

@test ".env.example: key list and example values are those of 091d9c8 (parsed, not diffed)" {
  git -C "$REPO_ROOT" show 091d9c8:.env.example > "$TEST_DIR/old" || skip "commit 091d9c8 not in this clone"
  value_parse "$TEST_DIR/old" > "$TEST_DIR/old.kv"
  value_parse "$REPO_ROOT/.env.example" > "$TEST_DIR/new.kv"
  [ "$(wc -l < "$TEST_DIR/new.kv")" -eq 76 ]
  diff "$TEST_DIR/old.kv" "$TEST_DIR/new.kv"
}

@test ".env.example: every key has a description and exactly one section" {
  example_parse "$REPO_ROOT/.env.example" > "$TEST_DIR/parsed"
  [ "$(wc -l < "$TEST_DIR/parsed")" -eq 76 ]
  [ "$(cut -f1 "$TEST_DIR/parsed" | sort -u | wc -l)" -eq 76 ]
  run awk -F'\t' '$3 == "" {print $1}' "$TEST_DIR/parsed"
  echo "no description: $output"
  [ -z "$output" ]
  # ./haven reads the same structure
  run in_haven 'for k in "${EX_KEYS[@]}"; do [[ "${EX_COMMENTED[$k]}" == 1 ]] && continue; printf "%s\t%s\t%s\n" "$k" "${EX_SECTIONS[${EX_SEC[$k]}]}" "${EX_DESC[$k]}"; done'
  [ "$status" -eq 0 ]
  [[ "$output" == "$(cat "$TEST_DIR/parsed")" ]]
}

@test ".env.example: env-upgrade on an .env made from the old example adds nothing and changes no value" {
  git -C "$REPO_ROOT" show 091d9c8:.env.example > "$SB/.env" || skip "commit 091d9c8 not in this clone"
  cp "$SB/.env" "$TEST_DIR/env.before"
  run in_haven 'list_missing_env_vars; echo "missing-done"; upgrade_env_file; echo "rc=$?"'
  [ "$status" -eq 0 ]
  [[ "$output" == $'missing-done\nrc=0' ]]
  cmp "$TEST_DIR/env.before" "$SB/.env"
  # and the CLI verb in a sandbox copy says so
  cp "$REPO_ROOT/haven" "$SB/"
  run env PATH="$REPO_ROOT/tests/mock:$PATH" "$SB/haven" env-upgrade </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"No missing variables"* ]]
  cmp "$TEST_DIR/env.before" "$SB/.env"
}

@test "settings: every key of .env.example is listed exactly once, under a section row" {
  run in_haven 'sec=""; for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do
      id="${MENU_IDS[$i]}"
      case "$id" in group:sec:*) sec="${MENU_LABELS[$i]}" ;; key:*) echo "${id#key:}	$sec" ;; esac
    done'
  [ "$status" -eq 0 ]
  example_parse "$REPO_ROOT/.env.example" | cut -f1,2 > "$TEST_DIR/want"
  [[ "$output" == "$(cat "$TEST_DIR/want")" ]]
}

@test "settings: no navigation key ever selects a section row (also with a filter)" {
  run in_haven '
    bad=""
    for f in "" limiter relay; do
      settings_set_filter "$f"
      n=${#MENU_IDS[@]}
      for key in up down k j home end g G 1 2 3 4 5 6 7 8 9; do
        for ((s = 0; s < n; s++)); do
          [[ "${MENU_IDS[$s]}" == group:* ]] && continue
          TUI_SEL=$s; tui_handle_key "$key"
          [[ "${MENU_IDS[$TUI_SEL]}" == group:* ]] && bad+="[$f] $key from $s; "
        done
      done
    done
    TUI_SEL=1; tui_clamp_sel; echo "clamp from the first section row: ${MENU_IDS[$TUI_SEL]}"
    echo "bad=[$bad]"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == *"bad=[]"* ]]
  [[ "$output" == *"clamp from the first section row: key:"* ]]
}

# page_dumps <cols> <lines> [extra .env line] — the left pane of the settings
# list, page by page, every row of the whole list once: "<entry index>\t<row>"
# (the marker of the selected row taken out). A section row pinned in the
# first row of a page (TUI_PIN) is listed under its own index, "P" marking it.
page_dumps() {
  local c="$1" l="$2" n
  COLS="$c" ROWS="$l" in_haven '
    { tui_draw_frame 0; tui_render_left_menu; } >/dev/null
    vis=$((LEFT_CONTENT_HEIGHT - 3)); n=${#MENU_IDS[@]}; p=0
    for ((off = 0; off < n; off += vis - 1)); do
      TUI_OFFSET=$off; TUI_SEL=$off
      while (( TUI_SEL < n )) && ! tui_menu_selectable "$TUI_SEL"; do TUI_SEL=$((TUI_SEL + 1)); done
      (( TUI_SEL < off + vis && TUI_SEL < n )) || TUI_SEL=$off
      { tui_draw_frame 0; tui_render_left_menu; } > "$S/page.$p"
      echo "$TUI_OFFSET $p $TUI_PIN"; p=$((p + 1))
    done' > "$TEST_DIR/pages"
  while read -r off p pin; do
    printf 'PAGE\t\n'
    python3 -I "$EMU" "$c" "$l" dump < "$SB/page.$p" | sed -n "7,$((l - 2))p" \
      | sed -E 's/^│ ?//; s/│.*$//; s/ +$//; s/^▸ /  /' \
      | awk -v o="$off" -v pin="$pin" '{ if (pin >= 0 && NR == 1) printf "%dP\t%s\n", pin, $0; else printf "%d\t%s\n", o + NR - 1 - (pin >= 0), $0 }'
  done < "$TEST_DIR/pages"
}

@test "settings: every row can be told apart at 66x20, 80x24, 100x24, 120x30, 160x40" {
  # Labels do not repeat their relay ("name", "npub" in four sections): no two
  # rows of one section are alike, and every page starts with the section of
  # its rows (the natural section row or the pinned one), or with Add setting.
  local size bad="" dump rows dups total heads
  for size in 66x20 80x24 100x24 120x30 160x40; do
    dump="$(page_dumps "${size%x*}" "${size#*x}")"
    rows="$(grep -v '^PAGE' <<<"$dump" | grep -v $'^[0-9]*P\t' | sort -u -t $'\t' -k1,1n | awk -F'\t' '$2 != ""')"
    total="$(wc -l <<<"$rows")"
    dups="$(awk -F'\t' '$2 !~ /^  / { sec = $2; next } { print sec "|" $2 }' <<<"$rows" | sort | uniq -d)"
    heads="$(awk -F'\t' '/^PAGE/ { first = 1; next } first { first = 0; if ($2 ~ /^  / && $2 !~ /Add setting/) print $0 }' <<<"$dump")"
    echo "$size: $total rows"
    [[ "$total" -ge 93 ]] || bad+="$size: only $total rows seen; "
    [[ -z "$dups" ]] || bad+="$size: alike in a section: $(tr '\n' '|' <<<"$dups"); "
    [[ -z "$heads" ]] || bad+="$size: pages without their section: $(tr '\n' '|' <<<"$heads"); "
  done
  echo "bad=[$bad]"
  [ -z "$bad" ]
}

@test "settings: the label is cut in the middle, its end survives" {
  run in_haven 'tui_truncate_middle "chat connection rate tokens per interval" 21 6; echo "[$_TRUNC]"
    tui_truncate_middle "short" 21 6; echo "[$_TRUNC]"'
  [ "$status" -eq 0 ]
  [[ "$output" == $'[chat c…s per interval]\n[short]' ]]
}

@test "settings: the 57-character key is fully readable in the details pane at 80 columns" {
  [ "${#LONGEST}" -eq 57 ]
  local screen keyrows
  screen="$(in_haven 'for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == "key:'"$LONGEST"'" ]] && TUI_SEL=$i; done
    tui_draw_frame 0; tui_render_left_menu; tui_render_right_details' | python3 -I "$EMU" 80 24 dump)"
  echo "$screen"
  keyrows="$(sed -n '4,8p' <<<"$screen" | sed -E 's/^.*│ //; s/ *│$//' | awk 'NF == 0 {exit} {printf "%s", $0}')"
  [ "$keyrows" = "$LONGEST" ]
  grep -q 'Default when' <<<"$screen"
  grep -q 'Example  3' <<<"$screen"
  grep -q 'Allowed  A whole number' <<<"$screen"
}

@test "settings: /limiter lists exactly the keys whose name or description contains limiter (32)" {
  # 24 keys carry LIMITER in the name (6 per relay rate-limit section), 8 more
  # mention it in their description (the ALLOW_*_FILTERS keys: "not one of
  # the rate limiters"); derived from .env.example by the parser above
  example_parse "$REPO_ROOT/.env.example" | awk -F'\t' 'tolower($1) ~ /limiter/ || tolower($3) ~ /limiter/ {print $1}' > "$TEST_DIR/want"
  [ "$(wc -l < "$TEST_DIR/want")" -eq 32 ]
  [ "$(grep -c LIMITER "$TEST_DIR/want")" -eq 24 ]
  run in_haven 'settings_set_filter limiter; for id in "${MENU_IDS[@]}"; do [[ "$id" == key:* ]] && echo "${id#key:}"; done; echo "sub=$MENU_SUBTITLE"'
  [ "$status" -eq 0 ]
  [[ "$output" == "$(cat "$TEST_DIR/want")"$'\nsub=Filter "limiter": 32 found' ]]
  # the matching is case-insensitive
  run in_haven 'settings_set_filter LiMiTeR; n=0; for id in "${MENU_IDS[@]}"; do [[ "$id" == key:* ]] && n=$((n + 1)); done; echo $n'
  [ "$output" = 32 ]
}

@test "settings: /zzz shows the empty-state row; Esc clears the filter first, then leaves" {
  run in_haven 'settings_set_filter zzz
    rows=""; for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:* ]] && rows+="KEY "; [[ "${MENU_IDS[$i]}" == group:empty:* ]] && rows+="${MENU_LABELS[$i]} "; done
    echo "[$rows]"
    tui_handle_key esc; echo "after esc: view=$TUI_VIEW filter=[$SETTINGS_FILTER]"
    tui_handle_key esc; echo "after esc: view=$TUI_VIEW"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == '[No setting matches "zzz". Esc clears the filter. ]
after esc: view=env_list filter=[]
after esc: view=main' ]]
}

@test "settings: the selection stays on its setting or is clamped when the list shrinks" {
  run in_haven '
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:HAVEN_LOG_LEVEL ]] && TUI_SEL=$i; done
    settings_set_filter limiter; tui_render_left_menu >/dev/null
    echo "clamped: ${MENU_IDS[$TUI_SEL]} ($TUI_SEL < ${#MENU_IDS[@]})"
    settings_set_filter ""
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL ]] && TUI_SEL=$i; done
    settings_set_filter chat_relay_event; tui_render_left_menu >/dev/null
    echo "kept: ${MENU_IDS[$TUI_SEL]}"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$(sed -n 1p <<<"$output")" == "clamped: key:PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL ("* ]]
  [ "$(sed -n 2p <<<"$output")" = "kept: key:CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL" ]
}

@test "settings: filtering, rendering and leaving never write .env" {
  local before
  before="$(sha256sum "$SB/.env")"
  run in_haven 'for f in limiter zzz "" npub; do settings_set_filter "$f"; tui_draw_frame 0; tui_render_left_menu; tui_render_right_details; done; tui_handle_key esc; tui_handle_key esc'
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$SB/.env")" = "$before" ]
}

@test "settings: a canary in a sensitive key never shows in the list, the details pane or the status view" {
  sed -i "s/^S3_SECRET_KEY=.*/S3_SECRET_KEY=\"$CANARY\"/" "$SB/.env"
  local screen all=""
  run in_haven 'for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:S3_SECRET_KEY ]] && TUI_SEL=$i; done
    tui_draw_frame 0; tui_render_left_menu; tui_render_right_details
    TUI_VIEW=main; TUI_RIGHT_MODE=status; tui_render_right_status'
  [ "$status" -eq 0 ]
  [[ "$output" != *CANARY* ]]
  [[ "$output" == *'…0042'* ]]   # the mask: last four characters of the value (quotes are not part of it)
  all="$(page_dumps 80 24; page_dumps 160 40)"
  [[ "$all" != *CANARY* ]]
  # control: with the mask stubbed out, the same details pane shows it
  run in_haven 'mask_env_value() { _MASKED="$1"; }
    for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:S3_SECRET_KEY ]] && TUI_SEL=$i; done
    tui_render_right_details'
  [[ "$output" == *"$CANARY"* ]]
}

@test "settings: masking hides credentials, not counts: limiter values shown, a canary in each masked key never shown" {
  # The rule (env_key_is_sensitive): a whole "_"-separated word of the key is a
  # credential word (SECRET, PASSWORD, TOKEN, KEY, ...), or the value is an
  # nsec. Of .env.example's keys exactly these two are masked:
  run in_haven 'for k in "${EX_KEYS[@]}"; do env_key_is_sensitive "$k" && echo "$k"; done; true'
  [ "$status" -eq 0 ]
  [ "$output" = $'S3_ACCESS_KEY_ID\nS3_SECRET_KEY' ]
  # direction 1: a limiter count (its key contains TOKENS) is shown, in the
  # list and in the details pane
  sed -i 's/^PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=.*/PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=4711/; s/^CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=.*/CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=4712/' "$SB/.env"
  local screen
  screen="$(in_haven 'for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL ]] && TUI_SEL=$i; done
    tui_draw_frame 0; tui_render_left_menu; tui_render_right_details' | python3 -I "$EMU" 80 24 dump)"
  echo "$screen"
  grep -qE '▸ event refill +4711 │' <<<"$screen"
  grep -q 'Current  4711' <<<"$screen"
  [[ "$(page_dumps 80 24)" == *$'\t  event burst          4712'* ]]
  # direction 2: a canary in each masked key, and an nsec in a key of no
  # credential name, reach neither the list, the details pane nor the status view
  sed -i "s/^S3_ACCESS_KEY_ID=.*/S3_ACCESS_KEY_ID=\"$CANARY-A\"/; s/^S3_SECRET_KEY=.*/S3_SECRET_KEY=\"$CANARY-S\"/" "$SB/.env"
  printf 'ZZ_NOTE="nsec1%s"\n' "$CANARY" >> "$SB/.env"
  local k all=""
  for k in S3_ACCESS_KEY_ID S3_SECRET_KEY ZZ_NOTE; do
    all+="$(in_haven 'for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == key:'"$k"' ]] && TUI_SEL=$i; done
      tui_draw_frame 0; tui_render_left_menu; tui_render_right_details
      TUI_VIEW=main; TUI_RIGHT_MODE=status; tui_render_right_status')"
  done
  all+="$(page_dumps 80 24; page_dumps 160 40)"
  [[ "$all" == *"S3_SECRET_KEY"* && "$all" == *"zz note"* ]]
  [[ "$all" != *CANARY* ]]
  # control: with the rule switched off the same renders do show the canaries
  all="$(in_haven 'env_key_is_sensitive() { return 1; }; tui_build_menu
    for k in S3_SECRET_KEY ZZ_NOTE; do
      for ((i = 0; i < ${#MENU_IDS[@]}; i++)); do [[ "${MENU_IDS[$i]}" == "key:$k" ]] && TUI_SEL=$i; done
      tui_setting_details; printf "%s" "${DETAIL_LINES[@]}"; echo
    done')"
  all="${all// /}"
  [[ "$all" == *"$CANARY-S"* && "$all" == *"nsec1$CANARY"* ]]
}

@test "settings: a key only in .env is listed under Other, last" {
  printf 'ZZ_ONLY_HERE=1\n' >> "$SB/.env"
  run in_haven 'n=${#MENU_IDS[@]}; echo "${MENU_IDS[$((n - 3))]}|${MENU_LABELS[$((n - 3))]} ${MENU_IDS[$((n - 2))]}|${MENU_LABELS[$((n - 2))]} ${MENU_IDS[$((n - 1))]}"'
  [ "$status" -eq 0 ]
  [ "$output" = "group:sec:other|Other key:ZZ_ONLY_HERE|zz only here back" ]
}

@test "settings: Tab switches details and logs; the bottom row names what Tab does next" {
  run in_haven 'tui_footer_hints; echo "$TUI_RIGHT_MODE: ${_HINTS//$'"'"'\n'"'"'/ }"
    tui_handle_key tab; tui_footer_hints; echo "$TUI_RIGHT_MODE: ${_HINTS//$'"'"'\n'"'"'/ }"
    tui_handle_key tab; echo "$TUI_RIGHT_MODE"
    tui_handle_key esc; echo "main: $TUI_RIGHT_MODE"'
  [ "$status" -eq 0 ]
  echo "$output"
  [[ "$output" == "details: ↑↓|Move ⏎|Open Esc|Back Tab|Logs /|Filter
logs: ↑↓|Move ⏎|Open Esc|Back Tab|Details /|Filter
details
main: logs" ]]
}
