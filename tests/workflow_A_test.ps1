# --- WORKFLOW A: INGESTION UNIT TEST ---
if (-not $RedisPass) { $RedisPass = Read-Host -MaskInput "Enter Redis Password" }

Write-Host "`n=== 🛡️ WORKFLOW A TEST SETUP ===" -ForegroundColor Cyan
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli FLUSHALL > $null

# 1. DEDUPLICATION TEST
Write-Host "`n[Test 1] Pushing Duplicates..."
$alert = '{"timestamp":"2025-12-12T10:00:00Z","rule":{"level":12,"description":"SSH Brute Force","id":"5710"},"agent":{"name":"srv","ip":"1.1.1.1"},"data":{"srcip":"10.0.0.5"}}'
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli LPUSH wazuh:alerts $alert > $null
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli LPUSH wazuh:alerts $alert > $null

Write-Host "⚠️  ACTION: Run Workflow A."
Pause

$lock = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET lock:alert:5710
if ($lock -eq "1") { Write-Host "✅ PASS: Lock created." -ForegroundColor Green }
else { Write-Host "❌ FAIL: No Lock found." -ForegroundColor Red }

# 2. DLQ TEST
Write-Host "`n[Test 2] Pushing Malformed Data..."
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli LPUSH wazuh:alerts '{"broken":"json"}' > $null

Write-Host "⚠️  ACTION: Run Workflow A."
Pause

$dlq = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli LLEN wazuh:errors
if ($dlq -ge 1) { Write-Host "✅ PASS: Error captured in DLQ." -ForegroundColor Green }
else { Write-Host "❌ FAIL: DLQ empty." -ForegroundColor Red }
