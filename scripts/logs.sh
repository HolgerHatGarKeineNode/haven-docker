#!/bin/sh

# Function to track the last 100 logs of a container
follow_logs() {
    container_name=$1
    docker logs --tail 100 -f "$container_name"
}

# Track logs for haven-relay
follow_logs haven-relay &

# Track logs for haven-tor when specified as an argument
if [[ "$1" == "haven-tor" || "$2" == "haven-tor" ]]; then
    follow_logs haven-tor &
fi

# Wait for CTRL+C to cancel log display
wait
