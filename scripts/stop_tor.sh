#!/bin/sh

# Check if either docker-compose or the Docker Compose plugin is installed
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "Docker Compose is not installed. Please install Docker Compose."
    exit 1
fi

# Use docker compose if available, otherwise fall back to docker-compose
DOCKER_COMPOSE_COMMAND="docker compose"
if command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_COMMAND="docker-compose"
fi

# Pull the latest images and start the services
echo "Stopping Docker Compose services..."
$DOCKER_COMPOSE_COMMAND -f docker-compose.tor.yml stop
