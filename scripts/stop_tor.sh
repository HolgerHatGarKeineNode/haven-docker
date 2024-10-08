#!/bin/sh

DOCKER_COMPOSE_COMMAND="docker compose"

# Pull the latest images and start the services
echo "Stopping Docker Compose services..."
$DOCKER_COMPOSE_COMMAND -f docker-compose.tor.yml stop
