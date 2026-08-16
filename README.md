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
./haven start             # Start (Docker Compose)
./haven start --tor       # Start with Tor hidden service
./haven stop              # Stop services
./haven restart           # Restart services
./haven logs              # Stream logs
./haven onion             # Show Tor .onion address
./haven json              # Edit JSON lists in TUI
./haven env-upgrade       # Add missing vars from .env.example
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
  `id -g` into `.env`; Compose alone falls back to `1000:1000`. See
  [File ownership](#file-ownership-db-permission-errors).
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

## Acknowledgements

Haven is built and maintained by [barrydeen](https://github.com/barrydeen) and its [contributors](https://github.com/barrydeen/haven/graphs/contributors). Thanks to everyone who makes this project possible.
