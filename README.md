# Haven Docker

Dockerized wrapper for [Haven](https://github.com/barrydeen/haven) — a **High Availability Vault for Events on Nostr**. Haven is a sovereign personal relay that bundles four specialized relays (Private, Chat, Inbox, Outbox) plus a Blossom media server into one self-hosted package, with web-of-trust filtering, note importing, cloud backups, and blastr broadcasting built in.

This repository packages Haven as a Docker Compose setup with a TUI for configuration and management.

## Quick start

1. Ensure **Docker** and **Docker Compose** are installed and running.

2. Get this repository onto the host. The Compose files, the example configs and
   the `./haven` CLI all live here, and every command below is run from inside
   the checkout:

```bash
git clone https://github.com/HolgerHatGarKeineNode/haven-docker.git
cd haven-docker
```

A clone is not strictly required — `docker-compose.yml` plus the config files is
a complete setup, see [Without the CLI](#without-the-cli-plain-docker-compose) —
but the examples, the CLI and `git pull` for new image versions come with it.

3. Copy the example files and edit them for your relay:

```bash
cp .env.example .env
cp relays_import.example.json relays_import.json
cp relays_blastr.example.json relays_blastr.json
cp blacklisted_npubs.example.json blacklisted_npubs.json
cp whitelisted_npubs.example.json whitelisted_npubs.json
```

The web dashboard templates are **baked into the image** — no host `templates/` copy is required for a default install.

4. Edit `.env` — at minimum set these to your own values:

| Variable | Description |
|---|---|
| `OWNER_NPUB` | Your nostr public key (npub) |
| `RELAY_URL` | Public hostname of your relay |
| `RELAY_PORT` | Port the relay listens on (default `3355`) |
| `PRIVATE_RELAY_NPUB` | npub for the private relay |
| `CHAT_RELAY_NPUB` | npub for the chat relay |
| `OUTBOX_RELAY_NPUB` | npub for the outbox relay |
| `INBOX_RELAY_NPUB` | npub for the inbox relay |

All relay names, descriptions, icons, rate limiters, WOT, backup, and import settings can also be configured in `.env`. See `.env.example` for the full list with comments.

5. Edit the JSON lists to fit your needs:

- `relays_import.json` — relays to import notes from
- `relays_blastr.json` — relays for blastr to broadcast to
- `blacklisted_npubs.json` — npubs to block
- `whitelisted_npubs.json` — npubs to allow (if whitelist mode)

6. Start the relay:

```bash
./haven
```

The TUI guides you through the remaining setup. Prefer plain Compose? `docker
compose up -d` works just as well — see
[Without the CLI](#without-the-cli-plain-docker-compose).

### File ownership (`db/` permission errors)

The container writes to the bind-mounted `./db` and `./blossom` directories and
runs as `${DOCKER_UID}:${DOCKER_GID}` (default `1000:1000`). If those directories
belong to a different uid, Haven fails to start with a permission error.

`./haven start` handles this for you: it creates the directories, writes your own
`id -u` / `id -g` into `.env` as `DOCKER_UID` / `DOCKER_GID`, and aborts with a
`chown` hint if the ownership still does not match.

**If you run `docker compose up` directly**, set both yourself before the first
start — otherwise Compose creates the directories as `root` and the container
cannot write to them:

```bash
printf 'DOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" >> .env
```

Do **not** work around this with `chmod -R 777 db/` — that makes the relay
database world-writable. Fix the ownership instead:

```bash
sudo chown -R "$(id -u):$(id -g)" db blossom
```

Ownership is all it takes: Compose creates a missing bind-mount source as
`root:root` with mode `0755`, so as soon as the directory is yours, the owner
bits already grant read and write. No `chmod` is involved in the fix.

**If you already ran `chmod -R 777`**, `chown` does not undo it — ownership and
mode bits are independent, and the database stays world-writable until you reset
the bits yourself:

```bash
chmod -R u=rwX,go= db blossom
```

Capital `X` sets the execute bit on directories only, so database files do not
end up executable. Nobody but your own user needs access here — the container
runs as `${DOCKER_UID}:${DOCKER_GID}`, which is you. Use `750`/`640` instead if
you want the group to read as well.

### Optional: customize the web dashboard

To override the baked-in templates, copy the examples and re-enable the volume in `docker-compose.yml` (and `docker-compose.tor.yml` if you use Tor):

```bash
cp -r templates-example/* templates/
```

```yaml
volumes:
  - "./templates:/app/templates"   # uncomment this line
```

A host bind-mount **replaces** the image copy entirely — an empty `./templates` directory will break the UI.

## CLI

```bash
./haven tui               # Interactive TUI (same as ./haven alone)
./haven start             # Start (Docker Compose)
./haven start --tor       # Start with Tor hidden service
./haven stop              # Stop services
./haven restart           # Restart services
./haven logs              # Stream logs
./haven status            # Show container status
./haven onion             # Show Tor .onion address
./haven env               # Edit .env in TUI
./haven json              # Edit JSON lists in TUI
./haven env-upgrade       # Add missing vars from .env.example
./haven import            # Import old notes once
./haven backup [file]     # Back up the relay data to backups/
./haven restore <file>    # Restore a backup from backups/
./haven db-switch <badger|lmdb>  # Move the data to the other engine
./haven help              # Full usage info
```

### Without the CLI: plain `docker compose`

`./haven` is convenience, not a requirement. It is a bash script on the host that
drives `docker compose` and edits `.env` for you; the image knows nothing about
it. `docker-compose.yml`, `.env` and the four JSON files are a complete setup,
and `docker compose up -d` is a supported way to run it.

| CLI | Plain Compose |
|---|---|
| `./haven start` | `docker compose up -d` |
| `./haven stop` | `docker compose down` |
| `./haven restart` | `docker compose restart` |
| `./haven logs` | `docker compose logs -f` |
| `./haven start --tor` | `docker compose -f docker-compose.tor.yml up -d` |
| `./haven import` | the three commands below |
| `./haven backup [file]` | [backup with plain Compose](#without-the-cli-backup-and-restore-with-plain-docker-compose) |
| `./haven restore <file>` | [restore with plain Compose](#without-the-cli-backup-and-restore-with-plain-docker-compose) |
| `./haven db-switch <badger\|lmdb>` | [the same steps by hand](#without-the-cli-backup-and-restore-with-plain-docker-compose) |

```bash
docker compose stop relay
docker compose run --rm --no-deps -e HAVEN_IMPORT_FLAG=true relay
docker compose start relay
```

`run` ignores the service's restart policy — that is the whole point. Stopping
the relay first is not optional: badger and lmdb take an exclusive lock on `db/`,
and the import is a second writer.

Four things the CLI does for you and you take on yourself here:

- **`DOCKER_UID` / `DOCKER_GID`** — `./haven start` writes your own `id -u` /
  `id -g` into `.env`; Compose alone falls back to the `1000:1000` in
  `user: "${DOCKER_UID:-1000}:${DOCKER_GID:-1000}"`. Check whether that is you:

  ```bash
  id -u; id -g                    # who you are on the host
  docker exec haven-relay id      # who the container writes as
  ls -ln db | head -3             # who owns the database files (numeric)
  ```

  Same numbers, nothing to do. Different ones, set them once and recreate the
  container — `user:` is part of its definition, so `restart` keeps the old uid:

  ```bash
  printf 'DOCKER_UID=%s\nDOCKER_GID=%s\n' "$(id -u)" "$(id -g)" >> .env
  sudo chown -R "$(id -u):$(id -g)" db blossom
  docker compose up -d
  ```

  More on this in [File ownership](#file-ownership-db-permission-errors).
- **All config files exist before the first start** — Compose creates a *missing*
  bind-mount source as a root-owned **directory**, so a forgotten
  `relays_import.json` comes back as a folder and the relay fails on it.
- **Updates** — the image tag in `docker-compose.yml` is pinned. `docker compose
  pull` will not move it: change the tag yourself (or `git pull` for the current
  one), then `docker compose up -d`.
- **`.env` drift** — `./haven start` compares your `.env` against the one
  upstream ships inside the image and names every variable you leave unset (each
  falls back to a built-in default). Without it, diff against `.env.example`
  after an update.

### Importing old notes

The relay never imports on its own. Importing is a separate, one-shot run of the
same binary — filling in `relays_import.json` and the `## Import Settings` in
`.env` configures it, but does not trigger it:

```bash
cd /path/to/haven-docker
./haven import      # runs the import once, in the foreground
```

It stops the relay first and starts it again afterwards — badger and lmdb both
take an exclusive lock on `db/`, so the import and the relay cannot both write.
Expect it to take a while. Your own notes end at `✅ owner note import
complete!`; the run then fetches the notes tagging you and finishes on
`✅ tagged import complete`.

**Run it on the host, from this repository — not inside the container.** Two
different programs are called `haven`: the `./haven` here is this repo's CLI, a
shell script that drives Docker Compose, while `/app/haven` inside the image is
upstream's relay binary. `docker exec haven-relay ./haven import` reaches the
second one and opens `db/` while the running relay still holds the lock, which
ends in `Cannot acquire directory lock on "db/private"`. Since `v1.2.2-4` the
image intercepts that call and points back here instead of panicking.

Driving Compose yourself instead of using the CLI? The same import in three
commands: [Without the CLI](#without-the-cli-plain-docker-compose).

`HAVEN_IMPORT_FLAG` is what decides it — `entrypoint.sh` reads it and runs
`haven import` instead of the relay. Where it is set makes the difference:

- **passed to a one-shot run** (`docker compose run -e HAVEN_IMPORT_FLAG=true`)
  is the correct path, and exactly what `./haven import` does under the hood.
  `run` ignores the restart policy, so the container is gone once the import ends.
- **written into `.env`** is the trap. The import exits when it finishes and
  `restart: unless-stopped` starts the container right back into it, so it
  imports in a loop and the relay never comes up. `./haven start` warns if it
  finds the flag set there.

What it fetches, from the relays in `relays_import.json`:

- your own notes, in 10-day windows from `IMPORT_START_DATE` up to now, into the outbox relay
- notes tagging you, into the inbox relay — gift-wrapped ones into the chat relay

Do **not** empty `relays_import.json` when the import is done. The running relay
reads it at every boot and needs it for three more things: the connectivity check
at startup, building the web of trust (follow lists are fetched from exactly
these relays), and the live inbox subscription. With an empty list the web of
trust shrinks to your whitelist and the inbox stops receiving anything.

After starting, `./haven start` compares your `.env` against the `.env.example`
that upstream Haven ships inside the image and names any variable the relay
supports but your `.env` leaves unset — it then runs on its built-in default.
`./haven env-upgrade` adds the ones this repo documents.

## Keyboard reference

The interactive TUI (`./haven` without arguments) understands:

| Key | Action |
|---|---|
| `↑` `↓` or `k` `j` | Move the menu selection |
| `g` / `G`, `Home` / `End` | Jump to the first / last menu entry |
| `1`–`9` | Select the nth menu entry directly (Enter opens it) |
| `Enter` | Open the selected entry |
| `←` / `Esc` | Go back one view |
| `q` | Back one view; from the main view, quit |
| `Tab` | Switch the right panel between the log view and the status view |
| `PgUp` / `PgDn` | Scroll the log panel backwards / forwards; a `paused` banner marks the scroll position and new lines keep buffering |
| `/` | Live filter for the log panel (case-insensitive substring) — the match count shows on the first panel row, an empty Enter clears the filter |

Inside an input prompt:

| Key | Action |
|---|---|
| `←` / `→` | Move the cursor within the input |
| `Ctrl-A` / `Ctrl-E` | Jump to the start / end of the input |
| `Backspace` / `Delete` | Delete before / after the cursor |
| `Ctrl-U` | Clear the input |
| `Ctrl-W` | Delete the word before the cursor |
| Paste | Pasted text inserts at the cursor position |
| `Enter` | Accept; invalid values show an inline error and keep editing |
| `Esc` / `Ctrl-C` | Cancel with the previous value |

## Backups and restore

### Relay data: `./haven backup` and `./haven restore`

```bash
./haven backup                 # writes backups/haven-backup-<date>-<time>.zip
./haven backup my-relay.zip    # same, with a name you choose
./haven restore my-relay.zip   # reads backups/my-relay.zip
```

Both stop the relay while they run and start it again afterwards if it was
running. The database allows only one writer, so this is not optional.

Where the file lands: always in `backups/` inside this checkout. The directory
is created with mode `700`, the zip with mode `600`. You give a file name, not a
path. A backup never overwrites an existing file. Every zip is checked with
`unzip -t` before it is called a backup.

What a backup contains: the events of all five relay databases (private, chat,
inbox, outbox, and the Blossom index), as five `.jsonl` files in one zip.

What a backup does **not** contain:

- the media files in `blossom/`
- your `.env`
- the JSON lists (`relays_import.json`, `relays_blastr.json`,
  `blacklisted_npubs.json`, `whitelisted_npubs.json`)

Copy those yourself. If you restore the Blossom index without the files in
`blossom/`, the list entries are there, but downloading them returns 404 until
the files are back.

A restore adds the events that are missing from the database. It never
deletes anything and never creates duplicates; events that exist only in the
database stay. If the database already holds data, `./haven restore` asks
first. In a script without a terminal, add `--yes`.

### Switching the database engine

Haven stores its data with one of two engines, `badger` or `lmdb`, set by
`DB_ENGINE` in `.env`. Changing that line alone does not move your data. To
switch, run one command:

```bash
./haven db-switch lmdb      # or: ./haven db-switch badger
```

It asks once, then:

1. stops the relay and writes a verified backup to `backups/haven-pre-switch-<engine>-<time>.zip`
2. moves the old database directories to `db/.pre-switch-<old engine>-<time>/`
3. sets `DB_ENGINE` in `.env`
4. restores the backup into a new database and checks it against the first backup
5. starts the relay again, if it was running

If a step fails, it puts the old directories back and sets `DB_ENGINE` to
match them; if it cannot, it tells you what to do. Your old data stays in `db/.pre-switch-<old engine>-<time>/`. `./haven` never
deletes it. Once you are sure the relay serves everything, deleting that
directory is your own step.

To go back after a switch:

```bash
./haven db-switch --rollback
```

This brings the old directories back and sets `DB_ENGINE` to match them. The
current directories are kept in `db/.post-switch-<engine>-<time>/`. Notes the
relay received after the switch are in there and are not carried back. If a
switch was interrupted (power loss, a killed terminal), the same command
finishes putting the old state back; until then `./haven start` refuses to
start the relay.

`db-switch` asks for confirmation. Without a terminal (in a script), add
`--yes`.

About lmdb's files: each of the five lmdb directories holds a `data.mdb` that
shows up as 256 GiB in `ls -l`. The file is sparse; only the space your data
needs is used on disk (`du -sh db` shows the real size). If you copy `db/`
yourself, use a tool that keeps sparse files sparse, such as
`cp --sparse=always`, `rsync --sparse` or `tar --sparse`. A plain copy can
try to write the full 256 GiB per directory.

#### If you already changed DB_ENGINE by hand

If you changed `DB_ENGINE` in `.env` and started the relay, the relay shows
none of your old notes. Nothing is lost. The relay did not move your data: it
started a new, empty database next to it. Both engines now have files side by
side in the same directories, and the relay reads only the files of the engine
in `.env`.

`./haven start` still starts the relay in this state, with a warning.
`./haven db-switch` without more options refuses and explains the choice. Pick
the side whose notes you want to keep with `--from`:

```bash
./haven db-switch lmdb --from badger
```

This makes a clean `lmdb` database from the `badger` side, which holds the
notes from before your change. Notes the relay received after your change are
on the other side. They are not copied over. All files of both engines are
kept in `db/.pre-switch-mixed-<time>/`, and `./haven db-switch --rollback`
puts that state back if you change your mind.

To keep the notes received since the change instead, take that side. When
`.env` now says `lmdb`:

```bash
./haven db-switch lmdb --from lmdb
```

### Config backups (`.env.bak.<time>`)

Every write to `.env` or the JSON lists (add, edit, remove, clear,
`env-upgrade`) first copies the file to a timestamped backup next to it —
`.env.bak.20260920153000` — and keeps the 10 most recent backups. To undo
a change, copy the newest backup back:

```bash
ls -1t .env.bak.* | head -1     # find the newest backup
cp .env.bak.20260920153000 .env # restore it
```

The relay picks the restored values up on the next restart
(`./haven restart`).

### Without the CLI: backup and restore with plain `docker compose`

The same backup without `./haven`. Run it in the directory that holds your
`docker-compose.yml`. `backups/` must exist and belong to the user the
container runs as (`DOCKER_UID`, normally you), or the backup cannot be
written:

<!-- recipe:backup — run verbatim by tests/real-docker/p4-readme-recipe.sh -->
```bash
mkdir -p -m 700 backups
docker compose stop relay
docker compose run --rm --no-deps -v ./backups:/app/backups --entrypoint /app/haven relay backup /app/backups/haven-backup.zip
docker compose start relay
unzip -t backups/haven-backup.zip
```

`unzip -t` must end with `No errors detected`. Do not rely on the exit code of
the backup alone: on a full disk it can report success and leave a broken zip.
The zip itself is written with mode `644`; the `700` on `backups/` is what
keeps it private.

Restore:

<!-- recipe:restore — run verbatim by tests/real-docker/p4-readme-recipe.sh -->
```bash
docker compose stop relay
docker compose run --rm --no-deps -v ./backups:/app/backups --entrypoint /app/haven relay restore /app/backups/haven-backup.zip
docker compose start relay
```

Switching the engine by hand is the same steps in this order: stop the relay,
make a backup and check it, move the old directories aside, change
`DB_ENGINE`, restore, start. For a switch to `lmdb`:

<!-- recipe:switch — run verbatim by tests/real-docker/p4-readme-recipe.sh -->
```bash
docker compose stop relay
docker compose run --rm --no-deps -v ./backups:/app/backups --entrypoint /app/haven relay backup /app/backups/before-switch.zip
unzip -t backups/before-switch.zip
mkdir db/old-engine
mv db/private db/chat db/outbox db/inbox db/blossom db/old-engine/
# now edit .env and set DB_ENGINE="lmdb"
docker compose run --rm --no-deps -v ./backups:/app/backups --entrypoint /app/haven relay restore /app/backups/before-switch.zip
docker compose up -d
```

The last step is `up -d`, not `start`: `start` restarts the existing container
with the settings it was created with, so it would still run the old engine on
the new directories and serve nothing. `up -d` recreates the container with
the new `DB_ENGINE`.

## Acknowledgements

Haven is built and maintained by [barrydeen](https://github.com/barrydeen) and its [contributors](https://github.com/barrydeen/haven/graphs/contributors). Thanks to everyone who makes this project possible.
