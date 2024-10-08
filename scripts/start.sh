#!/bin/sh

# Check if Docker and Docker Compose are installed
if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker."
    exit 1
fi

if ! command -v docker-compose &> /dev/null; then
    echo "Docker Compose is not installed. Please install Docker Compose."
    exit 1
fi

# Pull the latest images and start the services
echo "Starting Docker Compose services..."
docker-compose up -d

# Display the status of the services
docker-compose ps

# Tail logs (optional)
echo "Tailing logs. Press Ctrl+C to stop."
docker-compose logs -f
