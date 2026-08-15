# Use Debian-based Golang image for building
FROM golang:bookworm AS builder

# Install git and set working directory
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Build determinism and cache paths
RUN go env -w GOCACHE=/go-cache
RUN go env -w GOMODCACHE=/gomod-cache

# Clone the repository and build app
ARG REPO_URL=https://github.com/barrydeen/haven.git
ARG VERSION
RUN if [ -z "$VERSION" ]; then \
      echo "ERROR: VERSION is required (tag or commit SHA)." && exit 1; \
    fi && \
    git clone --depth 1 --single-branch --branch "${VERSION}" -- ${REPO_URL} .
RUN --mount=type=cache,target=/gomod-cache --mount=type=cache,target=/go-cache \
    go build -a -tags netgo -ldflags '-w -s -extldflags "-static"' -o haven .

# Final Alpine image (keeps latest tag intentionally)
FROM alpine:latest

ENV HAVEN_IMPORT_FLAG=false

# Add non-root user specification
RUN adduser -D -g '' nonroot

WORKDIR /app

# Copy Go application. It lands as haven-bin, not haven: /app/haven is a guard
# script (below) that intercepts a `docker exec haven-relay ./haven ...` into the
# running relay, where the database lock is already taken.
COPY --from=builder /app/haven ./haven-bin

# Copy the web dashboard templates + static assets. HAVEN serves its landing
# page from ./templates/index.html and ./templates/static at runtime
# (http.Dir("templates/static")), so without these the web UI 404s. Baking them
# in makes the image self-contained; a host bind-mount can still override them.
COPY --from=builder /app/templates ./templates

# Keep upstream's own .env.example in the image. Ours is a hand-maintained copy
# of it plus the Docker-only variables, and it drifted once without anyone
# noticing: Haven falls back to a built-in default for an undefined variable, so
# nothing fails — the setting is simply invisible. Shipping the original lets
# `./haven start` diff against it offline, pinned to the exact version built here.
COPY --from=builder /app/.env.example ./.env.example.upstream

# The name `haven` inside the image belongs to the guard, which execs haven-bin
# once it is satisfied that nothing else holds db/. Everything that used to call
# /app/haven — entrypoint.sh included — keeps working unchanged.
COPY haven-guard.sh /app/haven

# Ensure the main executable has the correct permissions
RUN chmod +x /app/haven-bin /app/haven

# Copy the entrypoint script
COPY entrypoint.sh /entrypoint.sh

# Ensure the entrypoint script has the correct permissions
RUN chmod +x /entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]

# Switch to non-root user
USER nonroot

# Expose port
EXPOSE 3355
