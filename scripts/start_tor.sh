#!/bin/sh

DOCKER_COMPOSE_COMMAND="docker compose"

# Stop and remove the old container if it exists
if [ "$(docker ps -aq -f name=haven-tor)" ]; then
    echo "Stopping and removing old container 'haven-tor'..."
    docker stop haven-tor
    docker rm haven-tor
fi

# Pull the latest images and start the services
echo "Starting Docker Compose services..."
$DOCKER_COMPOSE_COMMAND -f docker-compose.tor.yml up -d

# Display the status of the services
$DOCKER_COMPOSE_COMMAND -f docker-compose.tor.yml ps

# Wait a few seconds for services to stabilize
sleep 5

# Output the Onion hostname
ONION_HOST_FILE="tor/data/haven/hostname"
if [ -f "$ONION_HOST_FILE" ]; then
    echo "Onion Host:"
    cat "$ONION_HOST_FILE"
else
    echo "Onion host file not found."
fi
