#!/bin/sh

DOCKER_COMPOSE_COMMAND="docker compose"

echo "Stopping and removing old container 'haven-relay'..."
docker stop haven-relay
docker rm haven-relay
echo "Stopping and removing old container 'haven-tor'..."
docker stop haven-tor
docker rm haven-tor

# Ask the user if HAVEN_IMPORT_FLAG should be set
read -p "Do you want to import your old notes? (y/n): " IMPORT_FLAG_INPUT

# Determine the value for HAVEN_IMPORT_FLAG
if [ "$IMPORT_FLAG_INPUT" = "y" ]; then
  IMPORT_FLAG_VALUE="true"
else
  IMPORT_FLAG_VALUE="false"
fi

# Backup the .env file
cp .env .env.bak

# Update or add HAVEN_IMPORT_FLAG to the .env file
if grep -q "^HAVEN_IMPORT_FLAG=" .env; then
  # If HAVEN_IMPORT_FLAG exists, update it
  sed -i.bak "/^HAVEN_IMPORT_FLAG=/c\HAVEN_IMPORT_FLAG=$IMPORT_FLAG_VALUE" .env
else
  # If HAVEN_IMPORT_FLAG does not exist, add it
  echo "" >> .env
  echo "HAVEN_IMPORT_FLAG=$IMPORT_FLAG_VALUE" >> .env
fi

# Pull the latest images and start the services with the IMPORT_FLAG environment variable
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
