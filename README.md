# Haven Docker

Dockerized wrapper for [Haven](https://github.com/barrydeen/haven) — a **High Availability Vault for Events on Nostr**. Haven is a sovereign personal relay that bundles four specialized relays (Private, Chat, Inbox, Outbox) plus a Blossom media server into one self-hosted package, with web-of-trust filtering, note importing, cloud backups, and blastr broadcasting built in.

This repository packages Haven as a Docker Compose setup with a TUI for configuration and management.

## Quick start

1. Ensure **Docker** and **Docker Compose** are installed and running.

2. Copy the example files and edit them for your relay:

```bash
cp .env.example .env
cp -r templates-example/* templates/
cp relays_import.example.json relays_import.json
cp relays_blastr.example.json relays_blastr.json
cp blacklisted_npubs.example.json blacklisted_npubs.json
cp whitelisted_npubs.example.json whitelisted_npubs.json
```

3. Edit `.env` — at minimum set these to your own values:

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

4. Edit the JSON lists to fit your needs:

- `relays_import.json` — relays to import notes from
- `relays_blastr.json` — relays for blastr to broadcast to
- `blacklisted_npubs.json` — npubs to block
- `whitelisted_npubs.json` — npubs to allow (if whitelist mode)

5. Start the relay:

```bash
./haven
```

The TUI guides you through the remaining setup.

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

## Acknowledgements

Haven is built and maintained by [barrydeen](https://github.com/barrydeen) and its [contributors](https://github.com/barrydeen/haven/graphs/contributors). Thanks to everyone who makes this project possible.
