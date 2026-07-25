# Changelog

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
