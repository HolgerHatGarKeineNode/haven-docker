#!/bin/sh

stop_service() {
    service_name=$1
    echo "Stopping $service_name..."
    docker stop "$service_name"
    echo "Removing $service_name..."
    docker rm "$service_name"
}

stop_service haven-relay
stop_service haven-tor
