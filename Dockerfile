# Build stage
FROM golang:bookworm AS builder

WORKDIR /app
ARG REPO_URL=https://github.com/bitvora/haven.git
ARG VERSION

# Clone and build application
RUN git clone $REPO_URL . && git checkout $VERSION
RUN go mod download
RUN go build -o main .

# Final stage
FROM debian:bookworm-slim

WORKDIR /app

COPY --from=builder /app/main .

# Use a non-root user in final image for better security
ARG DOCKER_UID=1000
ARG DOCKER_GID=1000
RUN groupadd -g ${DOCKER_GID} appgroup && \
    useradd -u ${DOCKER_UID} -g appgroup -m appuser && \
    chown -R appuser:appgroup /app

USER appuser

EXPOSE 3355
CMD ["./main"]
