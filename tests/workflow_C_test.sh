#!/bin/bash
# --- WORKFLOW C: REPORTING UNIT TEST (BASH) ---
if [ -z "$REDIS_PASS" ]; then read -sp "Enter Redis Password: " REDIS_PASS; echo ""; fi

echo -e "\n=== 📈 WORKFLOW C TEST SETUP ==="

# 1. SETUP DATA
echo "[Action] Injecting Mock Data..."
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli SET stats:5710:count 10 > /dev/null
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli SET stats:6001:count 5 > /dev/null
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli SET index:active_rules '[5710, 6001]' > /dev/null
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli SET rules:5710 '{"name":"SSH Brute Force","level":12}' > /dev/null
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli SET rules:6001 '{"name":"Web Server Scan","level":7}' > /dev/null

echo -e "\n⚠️  ACTION: Run Workflow C (Reporting) NOW."
echo "    Expected: One Slack message, 'Incidents: 15', 'Active Rules: 2'."
read -p "Press [Enter] after execution..."

# 2. VERIFY RESET
VAL=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli GET stats:5710:count)
if [ "$VAL" == "0" ]; then echo -e "✅ PASS: Atomic Reset worked."; else echo -e "❌ FAIL: Count is $VAL (Expected 0)."; fi

# 3. ERROR HANDLING
echo -e "\n=== ERROR HANDLING TEST ==="
echo "[Action] Corrupting Index..."
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli SET index:active_rules "oops-not-json" > /dev/null

echo -e "\n⚠️  ACTION: Run Workflow C again."
echo "    Expected: Workflow finishes GREEN, but sends NO report."
read -p "Press [Enter] to finish..."
