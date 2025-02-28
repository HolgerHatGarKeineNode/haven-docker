#!/bin/sh

DOCKER_COMPOSE_COMMAND="docker compose"

echo "Stopping and removing old container 'haven-relay'..."
docker stop haven-relay
docker rm haven-relay

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

# Pull the latest images and start the services
echo "Starting Docker Compose services..."
$DOCKER_COMPOSE_COMMAND up --build -d

# Display the status of the services
$DOCKER_COMPOSE_COMMAND ps
