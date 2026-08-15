# Changelog

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
