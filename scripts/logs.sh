#!/bin/bash

# Funktion zum Verfolgen von Logs eines Containers
follow_logs() {
    container_name=$1
    docker logs -f "$container_name"
}

# Logs für haven-relay verfolgen
follow_logs haven-relay &

# Logs für haven-tor verfolgen, wenn als Argument angegeben
if [[ "$1" == "haven-tor" || "$2" == "haven-tor" ]]; then
    follow_logs haven-tor &
fi

# Auf STRG+C warten, um die Protokollanzeige abzubrechen
wait
