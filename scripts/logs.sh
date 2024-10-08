#!/bin/bash

# Function to display logs for a given service
show_logs() {
    service_name=$1
    docker compose logs "$service_name"
}

# Display logs for haven-relay
show_logs haven-relay

# Display logs for haven-tor if specified as an argument
if [[ "$1" == "haven-tor" || "$2" == "haven-tor" ]]; then
    show_logs haven-tor
fi
