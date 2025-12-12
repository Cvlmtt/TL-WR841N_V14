#!/bin/bash
echo "=== IMMEDIATE C2 TEST ==="

# Ferma tutto
docker compose down 2>/dev/null

echo "1. Verificando rete..."
docker network create c2-test-net 2>/dev/null || true

echo "2. Avviando SOLO il server prima..."
docker compose up -d c2-server

echo "3. Attendendo che il server sia pronto..."
sleep 5

echo "4. Controllando stato del server:"
docker logs --tail=5 c2-server

echo "5. Testando connettività al server..."
docker run --rm --network c2_docker_test_default alpine nc -zv c2-server 4444 2>&1 | grep "succeeded" && echo "✓ Server raggiungibile" || echo "✗ Server non raggiungibile"

echo ""
echo "6. Avviando i client (uno alla volta per test)..."
for i in {1..100}; do  # Prima solo 3 client per test
    echo "   Avvio client-$i..."
    docker compose up -d --build --scale c2-client=$i
    sleep 2
done

echo ""
echo "7. Stato finale:"
docker ps --filter "name=c2" --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}"

echo ""
echo "=== DEBUG ==="
echo "Log del server:"
docker logs --tail=10 c2-server

echo ""
echo "Log di un client:"
docker logs --tail=5 c2-client-1 2>/dev/null || echo "Client non trovato"

echo ""
echo "=== COMANDI ==="
echo "Collegati al server:    docker attach c2-server"
echo "Vedi tutti i log:       docker compose logs -f"
echo "Ferma tutto:            docker compose down"
