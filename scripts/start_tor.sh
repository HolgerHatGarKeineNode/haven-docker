#!/bin/sh

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker."
    exit 1
fi

# Check for Docker Compose (CLI plugin or standalone binary)
if command -v docker compose &> /dev/null; then
    # Use Docker CLI plugin for Compose if available
    COMPOSE_COMMAND="docker compose"
elif command -v docker-compose &> /dev/null; then
    # Fallback to standalone docker-compose if not found
    COMPOSE_COMMAND="docker-compose"
else
    echo "Docker Compose is not installed. Please install Docker Compose."
    exit 1
fi

# Pull the latest images and start the services
echo "Starting Docker Compose services with $COMPOSE_COMMAND..."
$COMPOSE_COMMAND up -d

# Display the status of the services
$COMPOSE_COMMAND ps

# Tail logs (optional)
echo "Tailing logs. Press Ctrl+C to stop."
$COMPOSE_COMMAND logs -f
