# Changelog

## Unreleased

No image change — `./haven` and docs only.

### Added

- `./haven start` warns when `db/` or `blossom/` are world-writable, so an earlier `chmod -R 777` workaround does not survive the ownership fix unnoticed; it warns and continues rather than aborting, since the relay does run — it is only exposed ([#9](https://github.com/HolgerHatGarKeineNode/haven-docker/issues/9))
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
