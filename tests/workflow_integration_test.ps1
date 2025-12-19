# --- WAZUH PIPELINE: INTEGRATION TEST SUITE (FINAL) ---
# Constraints:
# 1. API Rate Limit: ~15s per item (VirusTotal)
# 2. Deduplication: Identical alerts should process quickly (local count), distinct ones hit API.
# 3. Wait Time: Fixed at 120s.

# 0. AUTHENTICATION
if (-not $RedisPass) {
    $RedisPass = Read-Host -MaskInput "Enter Redis Password to authenticate"
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
Write-Host " 🔄 END-TO-END INTEGRATION TEST (120s Limit)" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

# 1. CLEAN SLATE
Write-Host "`n[Step 1] 🧹 Clearing System State..." -ForegroundColor Gray
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli FLUSHALL > $null
Write-Host "         Redis flushed. System ready." -ForegroundColor Gray

# 2. ATTACK SIMULATION (Triggering Workflow A)
Write-Host "`n[Step 2] ⚔️ Simulating Attacks..." -ForegroundColor Yellow

# Attack A: 5x SSH Brute Force (High Severity) - Identical Source (Should Dedup)
Write-Host "    -> Injecting 5x SSH Brute Force (ID: 5710)..."
1..5 | ForEach-Object {
    $json = '{"timestamp":"2025-12-12T10:00:00Z","rule":{"level":12,"description":"SSH Brute Force - Integration Test","id":"5710"},"agent":{"name":"test-server","ip":"10.0.0.1"},"data":{"srcip":"192.168.1.5"}}'
    docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli LPUSH wazuh:alerts $json > $null
}

# Attack B: 3x Web Scanner (Medium Severity) - Identical Source (Should Dedup)
Write-Host "    -> Injecting 3x Web Scanner (ID: 6001)..."
1..3 | ForEach-Object {
    $json = '{"timestamp":"2025-12-12T10:05:00Z","rule":{"level":7,"description":"Web Server Scan - Integration Test","id":"6001"},"agent":{"name":"test-server","ip":"10.0.0.1"},"data":{"srcip":"45.33.22.11"}}'
    docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli LPUSH wazuh:alerts $json > $null
}

# 3. PROCESSING WINDOW
$EstimatedTime = 120
Write-Host "`n[Step 3] ⏳ Waiting for Workflow A ($EstimatedTime Seconds)..." -ForegroundColor Cyan
Write-Host "         Processing 8 alerts. Deduplication should make this fast."

for ($i = 1; $i -le $EstimatedTime; $i++) {
    $percent = [math]::Round(($i / $EstimatedTime) * 100)
    Write-Progress -Activity "Workflow A Processing" -Status "Elapsed: $i / $EstimatedTime sec" -PercentComplete $percent
    Start-Sleep -Seconds 1
}
Write-Progress -Activity "Workflow A Processing" -Completed

# 4. STATE VERIFICATION
Write-Host "`n[Step 4] 🔍 Verifying Redis State..." -ForegroundColor Yellow

# Check Index
$index = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET index:active_rules
Write-Host "    -> Index Content: $index"

# Check Counts
$count5710 = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET stats:5710:count
$count6001 = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET stats:6001:count
Write-Host "    -> Counts: 5710=[$count5710/5] | 6001=[$count6001/3]"

# Check Metadata (The Critical Fix)
$meta5710 = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET rules:5710
Write-Host "    -> Metadata (5710): $meta5710"

if ($index -like "*5710*" -and $count5710 -eq "5" -and $meta5710 -like "*SSH*") {
    Write-Host "`n✅ PASS: Database Primed correctly." -ForegroundColor Green
} else {
    Write-Host "`n❌ FAIL: Database state incomplete." -ForegroundColor Red
    Write-Host "         Check Workflow A: Is it writing to 'rules:5710'?"
    exit
}

# 5. REPORT GENERATION
Write-Host "`n[Step 5] 📢 WAITING FOR SCHEDULER (Workflow C)" -ForegroundColor Magenta
Write-Host "    Data is ready. Wait for your scheduled run (or click Execute manually)."
Pause

# 6. FINAL CLEANUP CHECK
Write-Host "`n[Step 6] 🏁 Verifying Cleanup..." -ForegroundColor Yellow
$clean5710 = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET stats:5710:count

if ($clean5710 -eq "0" -or $clean5710 -eq "") {
    Write-Host "  ✅ SUCCESS: Counters reset to 0. Report Sent." -ForegroundColor Green
} else {
    Write-Host "  ⚠️  PENDING: Counters are still present. Report has not run yet." -ForegroundColor Yellow
}
