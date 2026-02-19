# Haven Docker

## Quick start

1) Ensure Docker + Docker Compose are installed and running.
2) Run the TUI:

```bash
./haven
```

The TUI guides you through setup, starts/stops services, offers a JSON editor for relays/npubs. If any `.example.json` files are missing their
`.json` counterparts or templates are missing, the start flow will suggest copying them.

## CLI (optional)

```bash
./haven start
./haven start --tor
./haven logs
./haven status
```
