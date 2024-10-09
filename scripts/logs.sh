#!/bin/sh

# Function to track the last 100 logs of a container
follow_logs() {
    container_name=$1
    docker logs --tail 100 -f "$container_name"
}

# Track logs for haven-relay
follow_logs haven-relay &

# Wait for CTRL+C to cancel log display
wait
