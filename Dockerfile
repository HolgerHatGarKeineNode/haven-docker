# Use Debian-based Golang image for building
FROM golang:bookworm AS builder

# Install git and set working directory
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Setup cache directories
RUN go env -w GOCACHE=/go-cache
RUN go env -w GOMODCACHE=/gomod-cache

# Clone the repository and build app
ARG REPO_URL=https://github.com/bitvora/haven.git
ARG VERSION
RUN git clone --branch ${VERSION} --single-branch ${REPO_URL} .
RUN --mount=type=cache,target=/gomod-cache --mount=type=cache,target=/go-cache \
    go build -ldflags="-w -s" -o main .

# Final Distroless image
FROM gcr.io/distroless/base

# Add non-root user specification
USER nonroot

WORKDIR /app

# Copy Go application
COPY --from=builder /app/main .

# Expose port and set command
EXPOSE 3355
CMD ["./main"]
