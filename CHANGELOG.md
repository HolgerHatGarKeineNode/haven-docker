# Changelog

## CLI — unreleased (backup, restore and database engine switch)

Changes to the `./haven` CLI on the host. No new image is needed: the new
verbs run the relay binary of the image you already have (tested with
`v1.2.2-6`) through `docker compose run`, with no change to `entrypoint.sh` or
the compose files. Moving from badger to lmdb, or back, is what
[#15](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/15) asked
for.

One file of the image changed as well: `haven-guard.sh`, the message shown when
`backup` or `restore` is run inside the running container, now names the host
commands. That wording is in an image only once the image is rebuilt; the
images published so far still show the old text.

### Added

- `./haven backup [file]` writes the relay data to a zip in `backups/` (default
  name `haven-backup-<date>-<time>.zip`). The zip is only called a backup after
  it was checked: complete, `unzip -t` clean, exactly five `.jsonl` entries.
  The exit code of the backup alone is not trusted, because on a full disk it
  reports success with a truncated zip. The output says what a backup does not
  contain: the media files in `blossom/`, `.env` and the JSON lists
- `./haven restore <file>` restores a zip from `backups/` after checking it
  first. It adds the events that are missing and never deletes anything; notes
  that are already there are skipped, while on lmdb a media (Blossom) index
  entry that is already there is listed once more per restore. When the
  database already holds data it asks first (`--yes` without a terminal)
- `./haven db-switch <badger|lmdb>` moves the data to the other engine: stop,
  verified backup, old directories renamed to `db/.pre-switch-<engine>-<time>/`,
  `DB_ENGINE` set, restore, a second backup compared entry by entry with the
  first, relay started again. A failure or a signal after the move puts the old
  directories and a matching `DB_ENGINE` back. The old directories are never
  deleted; removing them is left to you
- `./haven db-switch <target> --from <badger|lmdb>` for a `db/` whose
  directories hold files of both engines, the state a hand-edited `DB_ENGINE`
  leaves behind: it makes a clean database from the chosen side and keeps all
  files of both engines in `db/.pre-switch-mixed-<time>/`
- `./haven db-switch --rollback` finishes an interrupted switch, or undoes the
  last completed one; the directories it replaces are kept in
  `db/.post-switch-<engine>-<time>/`
- Machine-readable progress lines from `db-switch` (`::step <n>/<total>
  <name>`, `::result ok|rolled-back|failed`)
- README: backup and restore, what a backup does not contain, switching the
  engine, what to do after changing `DB_ENGINE` by hand, and the same backup,
  restore and switch with plain `docker compose`
- TUI: *Back up now*, *Restore a backup* and *Switch engine* run
  `./haven backup`, `./haven restore` and `./haven db-switch` and show their
  output while they run. Each asks first; a restore offers the zips in
  `backups/` newest first; a switch shows the engine on disk, the target, the
  size of `db/`, the free space and the age of the last backup, offers the two
  `--from` sides when `db/` holds both engines, and runs only after you type
  the engine name. The steps of a switch are listed as they pass, the title
  row counts how long the relay has been offline, and the result box names a
  failed step. Before anything runs, each says what happens to the relay and
  the data; the result box says what happened, the relay's state, where the
  data is and the next step. Other keys wait while a command runs; `Ctrl-C`
  stops it (a switch puts everything back) and a relay that ran is started
  again. After an interrupted switch, *Undo interrupted switch* runs
  `./haven db-switch --rollback`
- TUI settings editor: the settings in the sections of `.env.example` with a
  short name and the value (the section row stays at the top while the list
  scrolls), a details pane with the full name, a description, the current
  value, the values allowed and the example value; `/` finds settings by
  name, short name or description; settings only in `.env` are listed under
  *Other*
- TUI status view (`Tab`): relay state and uptime, Docker or Tor, the relay
  address (and the onion host on Tor), the engine on disk with the size of
  `db/` (and a word when `.env` names another engine or `db/` holds both),
  the size of `blossom/`, the newest backup or *never*, image and digest, the
  containers
- `.env.example`: a description above every setting, taken from upstream's
  documentation and code for v1.2.2, and section names in sentence case
- TUI settings editor: a value that contains `$` outside single quotes gets a
  note in the details pane and in the box after saving it: Docker Compose
  expands `$NAME` and `${NAME}` there; single quotes keep the value literal

### Changed

- Every start path (`start`, `restart`, the TUI menu, the restart after an
  `.env` edit) refuses to start the relay while an engine switch is unfinished,
  while the temporary container of a running or interrupted backup, restore
  or import still exists, and when
  `DB_ENGINE` names the other engine than the data in `db/` — started like
  that, the relay serves an empty database. Directories that hold both engines
  or disagree start with one warning line; when nothing in `db/` can be read,
  start says so in one line
- The `.env` editor in the TUI refuses to change or remove `DB_ENGINE` away
  from the data in `db/` and names the `db-switch` command instead
- Every write to `.env` keeps the file's mode and owner; a `0600` `.env` no
  longer becomes `0644`
- `./haven import`, `backup` and `restore` handle Ctrl-C, `kill` and a closed
  terminal while the relay is stopped: the temporary container doing the work
  is stopped and the relay is started again before the script exits
- `./haven env-upgrade` adds a missing `DB_ENGINE` line with the engine found
  in `db/` when the data there is of one engine, and says so; the relay treats
  a missing line as lmdb, so the example's `badger` would have hidden lmdb data
- `.env.example`: the lmdb default map size is 256 GiB per database file (the
  comment said ~273GB); the file is sparse
- TUI: the main menu is grouped into Relay, Data and Configure with a letter
  for every entry; the relay state follows *Relay*, the engine follows
  *Data*; row 1 names the view you are in; the bottom row names the keys that
  work right now
- TUI: only glyphs one cell wide; `NO_COLOR` turns off all colour (the
  selection keeps its marker in reverse video); dim text is lighter
- TUI: `Esc` and `←` in the main view no longer quit (`q` does); on
  `TERM=dumb` the TUI does not start and names the CLI commands instead
- TUI: message boxes longer than the pane scroll with `↑` `↓`

### Fixed

- The TUI masked every `.env` value whose key contains `TOKEN` or `KEY`
  anywhere, so the rate limiters' `*_TOKENS_PER_INTERVAL` and `*_MAX_TOKENS`
  showed as `…`. The word TOKENS now stays visible; the rule that masks is
  under *Security*. Of `.env.example` it masks `S3_ACCESS_KEY_ID` and
  `S3_SECRET_KEY`
- The settings editor refused `HAVEN_LOG_LEVEL=WARN`, the level Haven v1.2.2
  reads, and accepted `WARNING`, which Haven logs as INFO; it now takes `WARN`
  and refuses `WARNING` with a message naming `WARN`, and the details pane
  points out a stored `WARNING`
- The settings editor accepted day units in `WOT_REFRESH_INTERVAL` (`1d`),
  which Go's `time.ParseDuration` does not know: Haven stopped at start. It
  now asks for hours, minutes and seconds and refuses zero
- With a filter set in the TUI log panel, the first line of the filtered
  window was never drawn (a single match showed the count and no line)
- TUI input prompts took only as many characters as fit beside their label
  (about 15 at 80 columns), so an npub could be neither typed nor pasted; a
  prompt now takes up to 4096 characters and scrolls
- The TUI title row ran two cells past the terminal width
- A finished TUI prompt left its row on screen; `PgUp` with a log filter
  stopped one line short of the oldest match; a restart after an `.env`
  change stopped the relay before asking its questions about missing JSON
  lists; with Docker offline, Start, Stop, Restart and Import ended the TUI
- `.gitignore` covers the timestamped config backups (`.env.bak.<time>`,
  `<list>.json.bak.<time>`) and `backups/`
- A setting that is in `.env` more than once: the start checks and every
  other place that reads a setting use its last assignment, the one Docker
  Compose uses
- After a setting is saved in the TUI, the box reports the relay's real state
  as Docker shows it after the restart; a write that is refused or fails is
  shown in the box and restarts nothing
- A write to `.env` that is interrupted (Ctrl-C, `kill`, a closed terminal)
  finishes first or cleans up after itself; its temporary files
  (`.env.tmp.*`, `.env.pre.*`) are git-ignored
- The TUI restores the terminal after Ctrl-C and after `kill`; echo and line
  editing could stay off
- An error inside a TUI menu action is shown in its box and no longer resets
  the terminal under the running TUI

### Security

- `backups/` is created with mode `700` and the zip is written with mode
  `600`; backup and restore refuse a `backups/` that other users can write to
  or that is not owned by the container user
- Backup file names stay inside `backups/` (no `/`, no `..`, `.zip` only) and
  never overwrite a file; a restore reads only a regular file owned by the
  container user, never a symlink
- File names and arguments are printed with non-printable bytes replaced
- `db-switch` keeps the old database in `db/.pre-switch-<engine>-<time>/` and
  moves directories only through real directories it made itself: if one of
  its own directories under `db/` has been replaced by a symlink it refuses,
  and (with GNU `mv`) a move never lands inside a directory that appeared at
  the target name
- `db-switch --rollback` refuses to undo when the kept old database is missing
  some of the directories the switch put there, instead of reporting success
  on less data than before
- A value typed or pasted into the TUI settings editor could add lines to
  `.env`: `\n` typed as two characters became a line break on the way to the
  file, so a pasted `"My relay"\nOWNER_NPUB=…` set a second `OWNER_NPUB` that
  Compose used. Values are now written byte for byte (a typed `\n` stays a
  backslash and an `n`); the prompt drops line breaks, tabs and other control
  characters from a paste, and a value that still holds one (line break, tab,
  escape) when it is checked or written is refused for every setting, and so
  is one that starts with a quote but is not one quoted string; after every
  write `.env` must have the
  same lines as before (one more for a new setting), or the previous file is
  put back and the write fails
- A setting that is in `.env` more than once is shown with the value Compose
  uses (the last line), marked in the list and explained in the details;
  editing it changes that last line
- Single-quoted values follow the same backslash rule as double-quoted ones
  (`'a\'b'` is one value, `'My relay\'` is refused as unterminated), checked
  against what Docker Compose parses
- The TUI log pane removes terminal control sequences from log lines (one
  could set the terminal's clipboard or window title)
- A backup file name could carry terminal escape sequences through the TUI's
  restore flow (one crafted name set the terminal's clipboard). The restore
  list now shows only regular files whose names the restore command accepts;
  messages print file names and other foreign text as text, never as escape
  codes; everything a command prints during a flow is shown with all escape
  sequences and control characters removed, and the result box reads its
  sentences only from lines that start with them
- The settings editor masks more credentials: a key with a word (split at `_`
  and at camelCase) that ends in KEY, KEYS, TOKEN, SECRET(S), PASSWORD(S),
  PASSWD, PASS, PASSPHRASE, PW or PWD (`S3_SECRETKEY`, `APITOKEN`,
  `NGROK_AUTHTOKEN`, `DB_PWD`), or that is NSEC, SK, SEED, MNEMONIC, XPRV,
  MACAROON, RUNE, CREDENTIAL(S), AUTH, AUTHORIZATION, BUNKER, NWC or DSN; and
  any value that starts with `nsec1` or `ncryptsec1`, is 64 hex characters,
  contains `secret=` (a `bunker://` or `nostr+walletconnect://` URI) or is a
  URL with a `user:password@` part. Keys ending in FILE, PATH or DIR hold
  file paths and stay visible. Editing a setting no longer hands its current
  value to the input prompt, where a refused value used to be drawn in clear

## Image v1.2.2-6 — 2026-11-10 (Blossom BUD-11 fix)

### Fixed

- Blossom accepts BUD-11 authorization tokens (base64url, unpadded).
  Haven `v1.2.2` ships khatru `v0.19.1`, which decodes the `Authorization:
  Nostr <token>` header with standard base64 only, so BUD-11 clients got
  `404 invalid "Authorization": invalid base64 token` on every upload whose
  event JSON length is not a multiple of 3 — about two in three. Measured
  against `v1.2.2-5`: 4 of 6 base64url uploads rejected; this image: 12 of 12
  (both encodings) stored and read back with matching sha256.
  ([#13](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/13),
  upstream [barrydeen/haven#138](https://github.com/barrydeen/haven/issues/138))
- The fix is a temporary shim carried in `patches/` and applied on top of
  upstream `v1.2.2` at build time: it rewrites the token to padded standard
  base64 before khatru reads it; tokens it cannot decode pass through
  unchanged. It goes away once khatru decodes BUD-11 itself — the build fails
  if the patch stops applying.
  It sits in front of every relay endpoint, so khatru's NIP-86 management
  API accepts base64url tokens as well; standard tokens are byte-identical.
- Haven now reports its version as `v1.2.2+dirty` (relay info and
  User-Agent), because the build tree carries the patch.

## Image v1.2.2-5 — 2026-10-22 (security hotfix)

### Security

- Rebuilt on a fresh `alpine:latest` (`ca-certificates-bundle 20261020-r0`).
  The trust store no longer contains **emSign ECC Root CA - G3**, whose
  intermediates had trivially recoverable private keys (Mozilla bug
  [2083449](https://bugzilla.mozilla.org/show_bug.cgi?id=2083449); removed
  in NSS 3.131.1). Earlier images, including `v1.2.2-4` and older, still
  trust it — upgrade by pulling `v1.2.2-5` or `latest`.
- No code change; same upstream Haven `v1.2.2`.

## Unreleased

Hardening and quality-of-life pass over the `./haven` TUI, in six steps.

### Added

- Keyboard navigation: `j`/`k`, `g`/`G`, `Home`/`End` and digit shortcuts
  `1`–`9` for the menus; `Tab` switches the right panel between the log
  view and a status view (container running/exited with uptime, relay
  image digest, `du -sh` of `db/` and `blossom/`, refreshed at most every
  5 s)
- Log panel scrollback: a 1000-line ring buffer browsed with `PgUp`/`PgDn`;
  a `paused` banner marks the scroll position while new lines keep
  buffering, and `/` filters the panel live (case-insensitive substring,
  match count in the title row, empty Enter clears)
- A real input editor in prompts: cursor movement, `Ctrl-A`/`Ctrl-E`,
  `Backspace`/`Delete`, `Ctrl-U`, `Ctrl-W`, and paste inserts at the cursor
  instead of cancelling; bracketed paste is enabled for terminals that
  support it
- Inline validation at the prompt: invalid values (bad port, wrong npub
  format, …) show the exact error under the input line and keep editing —
  the view only changes on valid input or cancel
- Values of `.env` keys containing `SECRET`, `PASSWORD`, `TOKEN` or `KEY`
  are masked in the editor list (`…1234`) and only shown via an explicit
  *Reveal value* entry (display-only; the file itself stays plaintext)
- An *About* screen with the distributed CLI version (image tag from the
  compose file) and the running relay image digest
- Timestamped backups: every `.env`/JSON write first copies the file to
  `<file>.bak.<YYYYmmddHHMMSS>` (10 most recent kept); see the README for
  the restore path
- A test harness: 67 unit tests (bats) and a tmux-driven e2e rig with 35
  checks (terminal I/O, resize, too-small terminals, paste, navigation,
  masking, scrollback, filter, status view), plus a docker mock so the
  log-streaming tests run without a daemon — all local, no CI
- `./haven` now warns loudly before starting on an (almost) empty `.env`:
  starting used to sail through silently with only `DOCKER_UID`/`GID`
  auto-written, leaving the relay without owner or identity — the warning
  names every missing critical variable and points at `env-upgrade`

### Fixed

- `WOT_REFRESH_INTERVAL` values like `24h` were rejected while a bare,
  invalid-for-Go `24` passed: the earlier `*_INTERVAL` catch-all shadowed
  the dedicated duration branch (dead code); the dedicated branches now
  precede the catch-all
- One-line message bodies never rendered — `tui_message` dropped the last
  line of every message because the folded text was piped without a
  trailing newline (`read` hit EOF before yielding it)
- Pasting into the main menu quit the TUI: unknown escape sequences fell
  through to `esc`, which navigates back (quits from the main view); the
  key decoder now swallows unbound sequences and decodes
  Home/End/PgUp/PgDn/Delete/F1/F2 including SS3 and rxvt variants
- Terminal minimum: below 66×20 the TUI refuses to start before touching
  `stty` or the alternate screen, with a clear message; shrinking during
  runtime shows a placeholder instead of a garbled frame
- Resizes while a prompt or dialog was open drew into rows that no longer
  existed — prompts run in `$()` subshells that reset traps, so the
  SIGWINCH trap is re-armed locally and the prompt redraws at the new
  geometry
- Errors now stay visible after a TUI exit: `die` restores the terminal
  before printing instead of dying with the alternate screen buffer
- The log fifo raced in a shared `/tmp` (`mktemp -u` + `mkfifo`); it now
  lives in a private `mktemp -d` directory, the producer is killed via its
  process group (no orphaned `docker logs` children), and a dead producer
  restarts the stream within ~1 s
- Wide glyphs (CJK, Hangul, fullwidth forms, most emoji) shifted the frame
  borders out of alignment: truncation and padding now count display
  width, with an ASCII fast path
- `./haven` now refuses bash < 4.2 with a clear message (`printf
  %(%s)T` needs 4.2); `help` stays reachable on old shells

### Changed

- The main loop polls every 150 ms instead of 50 ms: keys register within
  one tick (23 ms measured), idle CPU drops to a third of the old load
- `shellcheck -S warning` runs clean over `haven`, `haven-guard.sh` and
  the test scripts

## v1.2.2-4

Upstream Haven is unchanged (`v1.2.2`); the image is rebuilt because `/app/haven`
inside it is now a guard script in front of the relay binary. Multi-arch
`linux/amd64` + `linux/arm64`, index digest
`sha256:d6be7789b779fb254f2bbbb4e6c2754ebc8dc8b13d89a3590432e22858fd5548`;
`latest` points at the same digest.

### Added

- The image intercepts `docker exec haven-relay ./haven <cmd>` while the relay is running, and prints where the command actually belongs instead of letting badger panic. Two different programs are called `haven` — this repo's CLI on the host and upstream's binary in the container — and reaching the second one through `docker exec` opens `db/` behind the relay's back, which ends in `panic: Cannot acquire directory lock on "db/private"`. The panic named neither program, so it read like a broken import rather than the wrong `haven` ([#12](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/12))
- README: `./haven import` is explicitly a host command, run from the repository checkout — with the `docker exec` variant named as the thing that does not work, and why

### Changed

- `Dockerfile` installs the relay binary as `/app/haven-bin` and `haven-guard.sh` as `/app/haven`. The guard scans `/proc` for a second `haven-bin` and execs the real binary when it finds none, so the relay under `entrypoint.sh` and the one-shot import container from `./haven import` both pass through untouched; `help`, `-h` and `--help` never touch the database and always pass
- `./haven import` verifies the relay container is actually gone after stopping it, instead of assuming the stop took. A stop that silently failed sent the import into exactly the badger lock panic above
- Bumped Docker image tag to `v1.2.2-4` in `docker-compose.yml` and `docker-compose.tor.yml`

## v1.2.2-3

Upstream Haven is unchanged (`v1.2.2`), but the image was rebuilt: it now carries
upstream's own `.env.example`, which is what the drift check below compares
against. Multi-arch `linux/amd64` + `linux/arm64`, index digest
`sha256:c6c298f335b2cde3df905e8bc832c8d3fa8517b5dde8c5e3a325fb419dbdb69b`;
`latest` points at the same digest.

### Removed

- `--import`, `--no-import` and `--prompt-import`, and the prompt that asked on every interactive start whether to import on the next one. They all set `HAVEN_IMPORT_FLAG`, which hands the import to the long-running service and therefore loops. `./haven import` replaces them; `HAVEN_IMPORT_FLAG` itself still works for anyone driving `docker compose` directly. **Breaking:** `./haven start --import` now fails with `Unknown argument`

### Fixed

- `.env.example` was missing `BLASTR_TIMEOUT_SECONDS`, the only variable that had drifted from upstream `.env.example` at the packaged version (`v1.2.2`); the relay was unaffected — Haven defaults it to `5` when unset — but it was neither documented nor editable in the TUI. Existing installs pick it up with `./haven env-upgrade` ([#11](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/11))

### Changed

- `./haven import` now runs the import once and returns, instead of only flipping `HAVEN_IMPORT_FLAG` for the next start. It stops the relay for the run (badger and lmdb take an exclusive lock on `db/`), starts it again afterwards, and uses `compose run`, which ignores the service's restart policy — the flag-based path could not, which is why leaving the flag on re-imports in a loop and never serves ([#12](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/12))
- `./haven start` warns when it finds `HAVEN_IMPORT_FLAG=true` in `.env`, naming that loop
- Bumped Docker image tag to `v1.2.2-3` in `docker-compose.yml` and `docker-compose.tor.yml`

### Added

- `Dockerfile` keeps upstream's own `.env.example` in the image as `/app/.env.example.upstream`, and `./haven start` diffs your `.env` against it after the start: it names every variable the packaged relay supports but your `.env` leaves unset (Haven then uses its built-in default), and flags separately any that this repo's `.env.example` does not document at all — the exact gap behind [#11](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/11). The check is offline and pinned to the built version; on an image without the file it skips silently
- `build.sh` runs the same diff after `build` and `buildx` and names any variable the freshly built image documents but `.env.example` does not — the maintainer-side half of the check, before a tag ships. It reports and never fails the build
- `./haven start` warns when `db/` or `blossom/` are world-writable, so an earlier `chmod -R 777` workaround does not survive the ownership fix unnoticed; it warns and continues rather than aborting, since the relay does run — it is only exposed ([#9](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/9))
- README: an "Importing old notes" section — the import is a separate one-shot run that `.env` alone does not trigger, and `relays_import.json` must not be emptied when it is done ([#12](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/12))
- README: how to undo an earlier `chmod -R 777` workaround — `chown` does not reset mode bits, so the relay database stays world-writable until the bits are reset explicitly ([#9](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/9))
- README: spelled out why ownership alone fixes the start failure — Compose creates a missing bind-mount source as `root:root` mode `0755`, which already grants the owner read and write

## v1.2.2-2

Tooling and docs only. `Dockerfile`, `entrypoint.sh` and `build.sh` are unchanged
since `v1.2.2-1`, so the `v1.2.2-2` image was not rebuilt — it is the `v1.2.2-1`
manifest mirrored under the new tag (same digest
`sha256:31bbbcf91eee3bf4e31f87298707f182dc8a36a67688f29afd5284a1e72a5b32`,
`linux/amd64` + `linux/arm64`). Pulling either tag gives you the same bits.

### Fixed

- Relay failed to start on hosts where the login user is not uid 1000: both compose files run the container as `${DOCKER_UID:-1000}:${DOCKER_GID:-1000}`, but neither variable was defined or documented anywhere, so the container could not write to the bind-mounted `./db` ([#9](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/9))
- `./haven start` no longer copies an example JSON into a same-named directory that a bare `docker compose up` left behind as root

### Added

- `./haven start` writes the host user's `id -u` / `id -g` into `.env` as `DOCKER_UID` / `DOCKER_GID`, leaving operator-set values alone
- `./haven start` creates `db/` and `blossom/` before Compose can create them as root, and aborts with the exact `chown` command when the container user could not write to them
- `.env.example`: documented `DOCKER_UID` / `DOCKER_GID` (commented out so the TUI can fill them in)
- README: file-ownership section covering the direct `docker compose up` path, recommending `chown` over `chmod -R 777`

### Changed

- Bumped Docker image tag to `v1.2.2-2` in `docker-compose.yml` and `docker-compose.tor.yml`

## v1.2.2-1

Hotfix packaging of upstream Haven `v1.2.2` (image tag only; binary unchanged).

### Fixed

- Bake HAVEN web dashboard templates into the image so the UI works without a host bind-mount (e.g. Kubernetes, bare `docker run`)

### Changed

- `docker-compose.yml` / `docker-compose.tor.yml`: templates volume is optional (commented out); image defaults win
- Bumped Docker image tag to `v1.2.2-1`
- README: templates copy is no longer required for quick start; documented optional customization
- `./haven` no longer prompts to copy templates on start

## v1.2.2

### Changed

- Updated repository URL from `bitvora/haven` to `barrydeen/haven` in `Dockerfile`, `build.sh`, and `templates-example/index.html`
- Bumped Docker image version from `v1.2.1` to `v1.2.2` in `docker-compose.yml` and `docker-compose.tor.yml`

### Removed

- Removed deprecated `npub` entry from `whitelisted_npubs.example.json`

## v1.2.1

### Fixed

- Quoted `WOT_REFRESH_INTERVAL` value in `.env.example` to prevent potential parsing issues with duration strings

### Changed

- Bumped Docker image version from `v1.2.0` to `v1.2.1` in `docker-compose.yml` and `docker-compose.tor.yml`
