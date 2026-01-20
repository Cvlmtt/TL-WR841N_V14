#!/bin/bash

# Controlla se è stato fornito il numero di client
if [ -z "$1" ]; then
  echo "Usage: $0 <number_of_clients>"
  exit 1
fi

NUM_CLIENTS=$1

# Ferma e rimuove i container, le reti e i volumi definiti nel docker-compose
echo "Stopping and removing existing containers..."
docker compose down

# Avvia i servizi in background, buildando le immagini e scalando il servizio client
echo "Starting server and $NUM_CLIENTS clients..."
docker compose up -d --build --scale client=$NUM_CLIENTS

echo "Done. Use 'docker ps' to see the running containers."
