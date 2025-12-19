# --- WORKFLOW C: REPORTING UNIT TEST ---
if (-not $RedisPass) { $RedisPass = Read-Host -MaskInput "Enter Redis Password" }

Write-Host "`n=== 📈 WORKFLOW C TEST SETUP ===" -ForegroundColor Cyan

# 1. SETUP DATA
Write-Host "[Action] Injecting Mock Data..." -ForegroundColor Gray
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli SET stats:5710:count 10 > $null
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli SET stats:6001:count 5 > $null
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli SET index:active_rules '[5710, 6001]' > $null
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli SET rules:5710 '{"name":"SSH Brute Force","level":12}' > $null
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli SET rules:6001 '{"name":"Web Server Scan","level":7}' > $null

Write-Host "`n⚠️  ACTION: Run Workflow C (Reporting) NOW." -ForegroundColor Magenta
Write-Host "    Expected: One Slack message, 'Incidents: 15', 'Active Rules: 2'."
Pause

# 2. VERIFY RESET
$c = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET stats:5710:count
if ($c -eq "0") { Write-Host "✅ PASS: Atomic Reset worked." -ForegroundColor Green }
else { Write-Host "❌ FAIL: Count is $c (Expected 0)." -ForegroundColor Red }

# 3. ERROR HANDLING TEST
Write-Host "`n=== ERROR HANDLING TEST ===" -ForegroundColor Yellow
Write-Host "[Action] Corrupting Index..."
docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli SET index:active_rules "oops-not-json" > $null

Write-Host "`n⚠️  ACTION: Run Workflow C again." -ForegroundColor Magenta
Write-Host "    Expected: Workflow finishes GREEN, but sends NO report."
Pause

Write-Host "`nTest Complete."
