<#
.SYNOPSIS
    Workflow B Verification: The "Response Engine"
    Simulates Slack Webhook POST -> Verifies Redis State
    Loads configuration from .env file
#>

# 1. LOAD .ENV CONFIGURATION
$EnvPath = Join-Path $PSScriptRoot "..\.env"
if (Test-Path $EnvPath) {
    Get-Content $EnvPath | ForEach-Object {
        if ($_ -match "^(?!#)(.+?)=(.*)$") {
            $name = $matches[1].Trim()
            $value = $matches[2].Trim()
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
    Write-Host "✅ Loaded configuration from .env" -ForegroundColor Green
} else {
    Write-Warning "⚠️  No .env file found. Using existing environment variables."
}

# 2. SET VARIABLES
# Ensure your .env has N8N_WEBHOOK_URL and REDIS_PASSWORD defined
$n8n_Webhook_URL = $env:N8N_WEBHOOK_URL 
$RedisPass = $env:REDIS_PASSWORD

if (-not $n8n_Webhook_URL) {
    Write-Error "❌ Missing N8N_WEBHOOK_URL. Please check your .env file."
    exit
}

Write-Host "`n=== 🖐️ WORKFLOW B TEST (INTERACTION) ===" -ForegroundColor Cyan
Write-Host "Target: $n8n_Webhook_URL" -ForegroundColor Gray

# 3. TEST IGNORE PATH (Whitelist)
Write-Host "`n[Test 1] Simulating 'Ignore' Click..." -ForegroundColor Yellow
$IgnorePayload = @{
    payload = (@{
        actions = @(@{ action_id = "action_ignore"; value = "ignore|10.50.50.5" })
        user = @{ username = "sec_analyst" }
        channel = @{ id = "C12345" }
        message = @{ ts = "1234567890.123456"; blocks = @() }
    } | ConvertTo-Json -Depth 5)
}

try {
    Invoke-RestMethod -Uri $n8n_Webhook_URL -Method Post -Body $IgnorePayload -ContentType "application/x-www-form-urlencoded" | Out-Null
    Write-Host "   > Webhook Sent." -ForegroundColor Gray
} catch {
    Write-Host "   > ❌ Webhook Failed. Is workflow active?" -ForegroundColor Red
    Write-Host "   > Error: $_" -ForegroundColor Red
}

# Verify Redis
Start-Sleep -Seconds 1
$wl = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli GET whitelist:10.50.50.5
if ($wl) { Write-Host "✅ PASS: Whitelist entry created." -ForegroundColor Green }
else { Write-Host "❌ FAIL: Redis key missing." -ForegroundColor Red }


# 4. TEST ISOLATE PATH (Task Queue)
Write-Host "`n[Test 2] Simulating 'Isolate' Click..." -ForegroundColor Yellow
$IsolatePayload = @{
    payload = (@{
        actions = @(@{ action_id = "action_isolate"; value = "isolate|Desktop-Agent-01" })
        user = @{ username = "sec_lead" }
        channel = @{ id = "C12345" }
        message = @{ ts = "1234567890.123456"; blocks = @() }
    } | ConvertTo-Json -Depth 5)
}

Invoke-RestMethod -Uri $n8n_Webhook_URL -Method Post -Body $IsolatePayload -ContentType "application/x-www-form-urlencoded" | Out-Null
Write-Host "   > Webhook Sent." -ForegroundColor Gray

# Verify Redis Queue
Start-Sleep -Seconds 1
$task = docker exec -e REDISCLI_AUTH="$RedisPass" redis redis-cli LPOP wazuh:actions
if ($task -match "Desktop-Agent-01") { Write-Host "✅ PASS: Task queued in 'wazuh:actions'." -ForegroundColor Green }
else { Write-Host "❌ FAIL: Queue empty or malformed." -ForegroundColor Red }

Write-Host "`nTest Complete."
