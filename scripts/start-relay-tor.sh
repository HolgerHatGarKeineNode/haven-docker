#!/bin/sh

DOCKER_COMPOSE_COMMAND="docker compose"

echo "Stopping and removing old container 'haven-relay'..."
docker stop haven-relay
docker rm haven-relay
echo "Stopping and removing old container 'haven-tor'..."
docker stop haven-tor
docker rm haven-tor

# Pull the latest images and start the services
echo "Starting Docker Compose services..."
$DOCKER_COMPOSE_COMMAND -f docker-compose.tor.yml up --build -d

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
