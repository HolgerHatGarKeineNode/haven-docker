#!/bin/sh

DOCKER_COMPOSE_COMMAND="docker compose"

stop_service() {
    service_name=$1
    echo "Stopping $service_name..."
    $DOCKER_COMPOSE_COMMAND stop "$service_name"
}

stop_service haven-relay
stop_service haven-tor
