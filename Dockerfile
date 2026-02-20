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
ARG REPO_URL=https://github.com/bitvora/haven.git
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

# Copy Go application
COPY --from=builder /app/haven .

# Ensure the main executable has the correct permissions
RUN chmod +x /app/haven

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
