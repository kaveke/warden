#!/bin/bash
# --- WORKFLOW A: INGESTION UNIT TEST (BASH) ---
if [ -z "$REDIS_PASS" ]; then read -sp "Enter Redis Password: " REDIS_PASS; echo ""; fi

echo -e "\n=== 🛡️ WORKFLOW A TEST SETUP ==="
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli FLUSHALL > /dev/null

# 1. DEDUPLICATION
echo -e "\n[Test 1] Pushing Duplicates..."
ALERT='{"timestamp":"2025-12-12T10:00:00Z","rule":{"level":12,"description":"SSH Brute Force","id":"5710"},"agent":{"name":"srv","ip":"1.1.1.1"},"data":{"srcip":"10.0.0.5"}}'
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli LPUSH wazuh:alerts "$ALERT" > /dev/null
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli LPUSH wazuh:alerts "$ALERT" > /dev/null

echo "⚠️  ACTION: Run Workflow A."
read -p "Press [Enter] after execution..."

LOCK=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli GET lock:alert:5710)
if [ "$LOCK" == "1" ]; then echo "✅ PASS: Lock created."; else echo "❌ FAIL: No Lock found."; fi

# 2. DLQ
echo -e "\n[Test 2] Pushing Malformed Data..."
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli LPUSH wazuh:alerts '{"broken":"json"}' > /dev/null

echo "⚠️  ACTION: Run Workflow A."
read -p "Press [Enter] after execution..."

DLQ=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli LLEN wazuh:errors)
if [ "$DLQ" -ge 1 ]; then echo "✅ PASS: Error captured in DLQ."; else echo "❌ FAIL: DLQ empty."; fi
