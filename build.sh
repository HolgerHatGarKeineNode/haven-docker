#!/usr/bin/env bash
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
DEFAULT_REPO_URL="https://github.com/barrydeen/haven.git"
DEFAULT_DOCKER_USER="holgerhatgarkeinenode"
DEFAULT_IMAGE_NAME="haven-docker"
DEFAULT_PLATFORM="linux/amd64"

# Name of the dedicated buildx builder
BUILDER_NAME="haven-builder"
# Retry transient build failures (e.g. flaky DNS over Starlink)
BUILD_RETRIES=3
RETRY_DELAY=5

NONINTERACTIVE=false

# ── Colors ────────────────────────────────────────────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ── Helper ────────────────────────────────────────────────────────────
prompt() {
    local var_name="$1" prompt_text="$2" default="${3:-}"
    # Skip prompt if variable is already set (via flag)
    local current_val="${!var_name:-}"
    if [[ -n "$current_val" ]]; then
        return
    fi

    if [[ "$NONINTERACTIVE" == "true" ]]; then
        if [[ -n "$default" ]]; then
            eval "$var_name=\"\$default\""
            return
        fi
        printf "${RED}Error: ${prompt_text} is required in non-interactive mode.${NC}\n" >&2
        exit 1
    fi

    if [[ -n "$default" ]]; then
        printf "${CYAN}${prompt_text}${NC} [${YELLOW}${default}${NC}]: "
    else
        printf "${CYAN}${prompt_text}${NC}: "
    fi
    read -r value
    value="${value:-$default}"
    if [[ -z "$value" ]]; then
        printf "${RED}Error: Input must not be empty.${NC}\n"
        exit 1
    fi
    eval "$var_name=\"\$value\""
}

confirm() {
    local prompt_text="$1"
    if [[ "$NONINTERACTIVE" == "true" ]]; then
        return 0
    fi
    printf "${YELLOW}${prompt_text}${NC} [y/N]: "
    read -r answer
    [[ "$answer" =~ ^[yY]$ ]]
}

header() {
    printf "\n${BOLD}── $1 ──${NC}\n\n"
}

die() {
    printf "${RED}Error: $1${NC}\n" >&2
    exit 1
}

env_keys() {
    # Reads the given file, or stdin when called without one.
    awk '
        {
            line = $0
            sub(/^[ \t]*/, "", line)
            sub(/^export[ \t]+/, "", line)
            ep = index(line, "=")
            if (ep == 0) next
            key = substr(line, 1, ep - 1)
            if (key ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print key
        }
    ' "$@" | LC_ALL=C sort -u
}

# Our .env.example is a hand-maintained copy of upstream's plus the Docker-only
# variables, and it drifted once without anyone noticing (issue #11): Haven falls
# back to a built-in default for an undefined variable, so nothing fails — the
# setting is simply invisible. `./haven start` reports this to the operator, but
# by then the release has shipped. The image carries upstream's own file, so say
# it here, while the tag is still in the maintainer's hands.
check_env_example_drift() {
    local image="$1"
    local script_dir upstream missing
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    header "Env Drift Check"

    if [[ ! -f "$script_dir/.env.example" ]]; then
        printf "${YELLOW}Skipped: no .env.example next to build.sh.${NC}\n"
        return 0
    fi

    # Pulls if the image is not local — the buildx path pushes without loading.
    if ! upstream="$(docker run --rm --entrypoint cat "$image" \
        /app/.env.example.upstream 2>/dev/null)" || [[ -z "$upstream" ]]; then
        printf "${YELLOW}Skipped: cannot read /app/.env.example.upstream from ${image}.${NC}\n"
        printf "${YELLOW}Expected for a foreign --platform without emulation, or an image built before that file existed.${NC}\n"
        return 0
    fi

    missing="$(LC_ALL=C comm -23 \
        <(printf '%s\n' "$upstream" | env_keys) \
        <(env_keys "$script_dir/.env.example") | paste -sd ' ' -)"

    if [[ -z "$missing" ]]; then
        printf "${GREEN}.env.example covers every variable upstream ${VERSION} documents.${NC}\n"
        return 0
    fi

    printf "${RED}.env.example does not document variables that upstream ${VERSION} ships:${NC}\n"
    printf "  ${YELLOW}%s${NC}\n\n" "$missing"
    printf "Add them to .env.example before releasing. Haven runs on its built-in\n"
    printf "defaults for these, so nothing breaks — the settings are just invisible.\n"
}

# ── Usage ─────────────────────────────────────────────────────────────
usage() {
    printf '%b\n' "${BOLD}Haven Docker Build Script${NC}

${BOLD}Usage:${NC}
  ./build.sh <command> [flags]

${BOLD}Commands:${NC}
  build       Build Docker image locally
  push        Push an existing image to Docker Hub
  buildx      Multi-arch build + push via Buildx
  help        Show this help

${BOLD}Flags (optional – without flags you will be prompted interactively):${NC}
  --version, -v   Git branch/tag (VERSION)                         ${YELLOW}[required for build/buildx]${NC}
  --repo          Repository URL                        ${YELLOW}[${DEFAULT_REPO_URL}]${NC}
  --user, -u      Docker Hub username                   ${YELLOW}[${DEFAULT_DOCKER_USER}]${NC}
  --image, -i     Image name                            ${YELLOW}[${DEFAULT_IMAGE_NAME}]${NC}
  --tag, -t       Image tag                             ${YELLOW}[= VERSION]${NC}
  --platform, -p  Platform (linux/amd64, linux/arm64)   ${YELLOW}[${DEFAULT_PLATFORM}]${NC}
  --no-latest     Do NOT also tag as 'latest'                       ${YELLOW}[latest is tagged by default]${NC}
  --yes, -y       Skip confirmation prompts

${BOLD}Examples:${NC}
  ./build.sh build -v v1.2.0
  ./build.sh build -v v1.2.0 -p linux/arm64 --no-latest
  ./build.sh push  --user holgerhatgarkeinenode --image haven-docker --tag v1.2.0 --yes
  ./build.sh buildx -v v1.2.0 -p linux/amd64,linux/arm64
  ./build.sh build   ${CYAN}# interactive mode${NC}"
}

# ── Parse Args ────────────────────────────────────────────────────────
COMMAND=""
VERSION=""
REPO_URL=""
DOCKER_USER=""
IMAGE_NAME=""
IMAGE_TAG=""
PLATFORM=""
TAG_LATEST=true

parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 0
    fi

    COMMAND="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version|-v)  VERSION="$2";     shift 2 ;;
            --repo)        REPO_URL="$2";    shift 2 ;;
            --user|-u)     DOCKER_USER="$2"; shift 2 ;;
            --image|-i)    IMAGE_NAME="$2";  shift 2 ;;
            --tag|-t)      IMAGE_TAG="$2";   shift 2 ;;
            --platform|-p) PLATFORM="$2";    shift 2 ;;
            --latest)      TAG_LATEST=true;  shift ;;
            --no-latest)   TAG_LATEST=false; shift ;;
            --yes|-y)      NONINTERACTIVE=true;  shift ;;
            --help|-h)     usage; exit 0 ;;
            *) die "Unknown parameter: $1" ;;
        esac
    done
}

# ── Collect missing params interactively ──────────────────────────────
collect_params() {
    header "Haven Docker Build Script"

    prompt VERSION     "Git branch/tag (VERSION)"
    prompt REPO_URL    "Repository URL (REPO_URL)"   "$DEFAULT_REPO_URL"
    prompt DOCKER_USER "Docker Hub username"          "$DEFAULT_DOCKER_USER"
    prompt IMAGE_NAME  "Image name"                   "$DEFAULT_IMAGE_NAME"

    # IMAGE_TAG defaults to VERSION
    if [[ -z "$IMAGE_TAG" ]]; then
        prompt IMAGE_TAG "Image tag" "$VERSION"
    fi
}

collect_push_params() {
    header "Haven Docker Build Script"

    prompt DOCKER_USER "Docker Hub username" "$DEFAULT_DOCKER_USER"
    prompt IMAGE_NAME  "Image name"          "$DEFAULT_IMAGE_NAME"

    if [[ -z "$IMAGE_TAG" ]]; then
        prompt IMAGE_TAG "Image tag" "latest"
    fi
}

collect_platform() {
    if [[ -n "$PLATFORM" ]]; then
        return
    fi
    header "Platform Selection"
    printf "  1) linux/amd64              (Standard x86_64)\n"
    printf "  2) linux/arm64              (ARM, e.g. Apple Silicon / Raspberry Pi)\n"
    if [[ "$COMMAND" == "buildx" ]]; then
        printf "  3) linux/amd64,linux/arm64  (Multi-arch)\n"
    fi
    printf "\n"
    local choice
    prompt choice "Select platform" "1"
    case "$choice" in
        1) PLATFORM="linux/amd64" ;;
        2) PLATFORM="linux/arm64" ;;
        3) [[ "$COMMAND" == "buildx" ]] && PLATFORM="linux/amd64,linux/arm64" || die "Multi-arch only available with 'buildx'" ;;
        *) die "Invalid selection." ;;
    esac
}

# ── Ensure buildx builder ─────────────────────────────────────────────
# Create (or recreate) the buildx builder with host networking so buildkit
# resolves DNS via the host resolver (systemd-resolved) instead of querying
# the upstream nameserver directly. This avoids UDP DNS timeouts on
# high-latency links such as Starlink.
ensure_builder() {
    if docker buildx inspect "$BUILDER_NAME" &>/dev/null; then
        # Recreate only if the existing builder lacks host networking
        if ! docker buildx inspect "$BUILDER_NAME" 2>/dev/null | grep -q "network=host"; then
            printf "${YELLOW}Recreating builder '%s' with host networking...${NC}\n" "$BUILDER_NAME"
            docker buildx rm "$BUILDER_NAME" &>/dev/null || true
            docker buildx create --name "$BUILDER_NAME" --use --driver-opt network=host >/dev/null
        else
            docker buildx use "$BUILDER_NAME"
        fi
    else
        docker buildx create --name "$BUILDER_NAME" --use --driver-opt network=host >/dev/null
    fi
    docker buildx inspect --bootstrap "$BUILDER_NAME" >/dev/null
}

# ── Derive image names ────────────────────────────────────────────────
setup_image_names() {
    FULL_IMAGE="${DOCKER_USER}/${IMAGE_NAME}:${IMAGE_TAG}"
    LATEST_IMAGE="${DOCKER_USER}/${IMAGE_NAME}:latest"
}

# ── Summary ───────────────────────────────────────────────────────────
show_summary() {
    header "Summary"
    printf "  Action:     ${GREEN}${COMMAND}${NC}\n"
    [[ "$COMMAND" != "push" ]] && printf "  VERSION:    ${GREEN}${VERSION}${NC}\n"
    [[ "$COMMAND" != "push" ]] && printf "  REPO_URL:   ${GREEN}${REPO_URL}${NC}\n"
    printf "  Image:      ${GREEN}${FULL_IMAGE}${NC}\n"
    [[ "$COMMAND" != "push" ]] && printf "  Platform:   ${GREEN}${PLATFORM}${NC}\n"
    printf "  Latest:     ${GREEN}${TAG_LATEST}${NC}\n"
    printf "\n"

    if ! confirm "Proceed?"; then
        printf "Cancelled.\n"
        exit 0
    fi
}

# ── Commands ──────────────────────────────────────────────────────────
cmd_build() {
    collect_params
    collect_platform
    setup_image_names
    show_summary

    header "Docker Build"
    printf "${GREEN}Starting local build for ${PLATFORM}...${NC}\n\n"

    docker build \
        --platform "$PLATFORM" \
        --build-arg VERSION="$VERSION" \
        --build-arg REPO_URL="$REPO_URL" \
        -t "$FULL_IMAGE" \
        .

    printf "\n${GREEN}Build successful: ${FULL_IMAGE}${NC}\n"

    if $TAG_LATEST; then
        docker tag "$FULL_IMAGE" "$LATEST_IMAGE"
        printf "${GREEN}Tagged: ${LATEST_IMAGE}${NC}\n"
    fi

    check_env_example_drift "$FULL_IMAGE"

    printf "\n${BOLD}Done.${NC}\n"
}

cmd_push() {
    collect_push_params
    setup_image_names
    show_summary

    header "Docker Push"

    if ! docker image inspect "$FULL_IMAGE" &>/dev/null; then
        die "Image '${FULL_IMAGE}' not found locally. Run './build.sh build' first."
    fi

    docker login
    printf "${GREEN}Pushing ${FULL_IMAGE}...${NC}\n"
    docker push "$FULL_IMAGE"

    if $TAG_LATEST; then
        if ! docker image inspect "$LATEST_IMAGE" &>/dev/null; then
            docker tag "$FULL_IMAGE" "$LATEST_IMAGE"
        fi
        printf "${GREEN}Pushing ${LATEST_IMAGE}...${NC}\n"
        docker push "$LATEST_IMAGE"
    fi

    printf "\n${GREEN}Push successful!${NC}\n"
    printf "\n${BOLD}Done.${NC}\n"
}

cmd_buildx() {
    collect_params
    collect_platform
    setup_image_names
    show_summary

    header "Docker Buildx Build + Push"

    docker login

    ensure_builder

    local tag_args="-t ${FULL_IMAGE}"
    if $TAG_LATEST; then
        tag_args="${tag_args} -t ${LATEST_IMAGE}"
    fi

    printf "${GREEN}Starting Buildx build + push for ${PLATFORM}...${NC}\n\n"

    local attempt=1
    until docker buildx build \
            --platform "$PLATFORM" \
            --build-arg VERSION="$VERSION" \
            --build-arg REPO_URL="$REPO_URL" \
            $tag_args \
            --push \
            .
    do
        if (( attempt >= BUILD_RETRIES )); then
            die "Buildx build failed after ${BUILD_RETRIES} attempts."
        fi
        printf "${YELLOW}Attempt %d/%d failed (often transient DNS/network on Starlink). Retrying in %ds...${NC}\n" \
            "$attempt" "$BUILD_RETRIES" "$RETRY_DELAY" >&2
        attempt=$((attempt + 1))
        sleep "$RETRY_DELAY"
    done

    printf "\n${GREEN}Buildx build + push successful!${NC}\n"
    printf "  ${FULL_IMAGE}\n"
    $TAG_LATEST && printf "  ${LATEST_IMAGE}\n"

    # Buildx pushes without loading into the local daemon, so this pulls the tag
    # back for the host platform. Worth one pull per release.
    check_env_example_drift "$FULL_IMAGE"

    printf "\n${BOLD}Done.${NC}\n"
}

# ── Main ──────────────────────────────────────────────────────────────
parse_args "$@"

case "$COMMAND" in
    build)  cmd_build ;;
    push)   cmd_push ;;
    buildx) cmd_buildx ;;
    help)   usage ;;
    *)      die "Unknown command: '${COMMAND}'. See './build.sh help'." ;;
esac
