#!/bin/bash
# --- WAZUH PIPELINE: INTEGRATION TEST SUITE (BASH) ---

echo "================================================================="
echo " 🔄 END-TO-END INTEGRATION TEST (120s Limit)"
echo "================================================================="

# 0. AUTHENTICATION
if [ -z "$REDIS_PASS" ]; then
    read -sp "Enter Redis Password to authenticate: " REDIS_PASS
    echo ""
fi

# 1. CLEAN SLATE
echo -e "\n[Step 1] 🧹 Clearing System State..."
docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli FLUSHALL > /dev/null
echo "         Redis flushed. System ready."

# 2. ATTACK SIMULATION
echo -e "\n[Step 2] ⚔️ Simulating Attacks..."

echo "    -> Injecting 5x SSH Brute Force (ID: 5710)..."
JSON_A='{"timestamp":"2025-12-12T10:00:00Z","rule":{"level":12,"description":"SSH Brute Force - Integration Test","id":"5710"},"agent":{"name":"test-server","ip":"10.0.0.1"},"data":{"srcip":"192.168.1.5"}}'
for i in {1..5}; do
    docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli LPUSH wazuh:alerts "$JSON_A" > /dev/null
done

echo "    -> Injecting 3x Web Scanner (ID: 6001)..."
JSON_B='{"timestamp":"2025-12-12T10:05:00Z","rule":{"level":7,"description":"Web Server Scan - Integration Test","id":"6001"},"agent":{"name":"test-server","ip":"10.0.0.1"},"data":{"srcip":"45.33.22.11"}}'
for i in {1..3}; do
    docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli LPUSH wazuh:alerts "$JSON_B" > /dev/null
done

# 3. PROCESSING WINDOW
EST_TIME=120
echo -e "\n[Step 3] ⏳ Waiting for Workflow A ($EST_TIME Seconds)..."
for ((i=1; i<=EST_TIME; i++)); do
    echo -ne "         Elapsed: $i / $EST_TIME sec\r"
    sleep 1
done
echo -e "\n         Processing Complete."

# 4. STATE VERIFICATION
echo -e "\n[Step 4] 🔍 Verifying Redis State..."

INDEX=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli GET index:active_rules)
echo "    -> Index Content: $INDEX"

COUNT5710=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli GET stats:5710:count)
COUNT6001=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli GET stats:6001:count)
echo "    -> Counts: 5710=[$COUNT5710/5] | 6001=[$COUNT6001/3]"

META5710=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli GET rules:5710)
echo "    -> Metadata (5710): $META5710"

if [[ "$INDEX" == *"5710"* && "$COUNT5710" == "5" && "$META5710" == *"SSH"* ]]; then
    echo -e "\n✅ PASS: Database Primed correctly."
else
    echo -e "\n❌ FAIL: Database state incomplete."
    echo "         Check Workflow A: Is it writing to 'rules:5710'?"
    exit 1
fi

# 5. REPORT GENERATION
echo -e "\n[Step 5] 📢 WAITING FOR SCHEDULER (Workflow C)"
echo "    Data is ready. Wait for your scheduled run (or click Execute manually)."
read -p "Press [Enter] once the report has arrived in Slack..."

# 6. FINAL CLEANUP CHECK
echo -e "\n[Step 6] 🏁 Verifying Cleanup..."
CLEAN5710=$(docker exec -e REDISCLI_AUTH="$REDIS_PASS" redis redis-cli GET stats:5710:count)

if [[ "$CLEAN5710" == "0" || -z "$CLEAN5710" ]]; then
    echo "  ✅ SUCCESS: Counters reset to 0. Report Sent."
else
    echo "  ⚠️  PENDING: Counters are still present. Report has not run yet."
fi

echo "================================================================="
echo " TEST COMPLETE"
echo "================================================================="
