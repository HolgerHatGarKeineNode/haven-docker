#!/bin/sh

DOCKER_COMPOSE_COMMAND="docker compose"

echo "Stopping and removing old container 'haven-relay'..."
docker stop haven-relay
docker rm haven-relay

# Pull the latest images and start the services
echo "Starting Docker Compose services..."
$DOCKER_COMPOSE_COMMAND up --build -d

# Display the status of the services
$DOCKER_COMPOSE_COMMAND ps
