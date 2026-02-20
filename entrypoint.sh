#!/bin/sh

log() {
  printf '%s\n' "$1"
}

ensure_file_from_example() {
  src="$1"
  dst="$2"

  if [ -f "$dst" ]; then
    return 0
  fi

  if [ -f "$src" ]; then
    log "WARN: $dst missing. Copying from ${src}."
    cp "$src" "$dst"
    return 0
  fi

  log "ERROR: Required file $dst not found and no template $src available."
  log "Hint: copy your config file before start.\n"
  return 1
}

ensure_json_artifacts() {
  ensure_file_from_example "$1.example.json" "$1"
}

ensure_env_file() {
  if [ -f "$1" ]; then
    return 0
  fi
  log "WARN: $1 missing. Copy .env.example to .env and fill values before start."
  return 0
}

ensure_list_files() {
  ensure_json_artifacts relays_import
  ensure_json_artifacts relays_blastr
  ensure_json_artifacts blacklisted_npubs
  ensure_json_artifacts whitelisted_npubs
  ensure_env_file .env
}

if [ "$HAVEN_IMPORT_FLAG" = "true" ]; then
  exec /app/haven import
else
  if ! ensure_list_files; then
    exit 1
  fi
  exec /app/haven
fi
