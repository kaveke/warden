# 🛡️ Wazuh SOAR Pipeline: Ingestion & Reporting

This repository contains the automation logic for a **Security Orchestration, Automation, and Response (SOAR)** pipeline connecting **Wazuh**, **Redis**, and **n8n**. 

The system is split into two decoupled engines:
1.  **Workflow A (The Writer):** High-speed ingestion, deduplication, and state management.
2.  **Workflow C (The Reader):** Scheduled reporting, analytics generation, and atomic counters.

---

## 🏗️ Architecture Overview

The system uses a ** decoupled "Mailbox" pattern**. The Writer (A) drops mail (counts/metadata) into Redis, and the Reader (C) picks it up, summarizes it, and wipes the mailbox clean for the next shift.

### 🔄 Workflow A: The Ingestion Engine
* **Trigger:** Redis Queue (`wazuh:alerts`)
* **Responsibilities:**
    * **Deduplication:** Uses Redis Locks (`lock:alert:{{id}}`) to suppress identical signals for 1 minute.
    * **Rate Limiting:** Buffers external API calls (e.g., VirusTotal) to 15s intervals.
    * **State Updates:**
        * Increments counters: `stats:{{id}}:count`
        * Updates Metadata: `rules:{{id}}` (Name, Level)
        * Updates Index: `index:active_rules` (The "Table of Contents")

### 📈 Workflow C: The Reporting Engine
* **Trigger:** Cron Schedule (e.g., Every 4 Hours)
* **Responsibilities:**
    * **Deterministic Read:** Fetches the list of active alerts from `index:active_rules`.
    * **Context Hydration:** Joins counts with metadata (`rules:{{id}}`).
    * **SitRep Generation:** Calculates "Top Threat," "Intensity Score," and "Severity Buckets."
    * **Atomic Reset:** Wipes counters to `0` immediately after reading to ensure the next report starts fresh.

---

## 🧪 Test Suite Documentation

We use a set of **PowerShell (v7+)** and **Bash** scripts to validate the pipeline without needing live malware.

### 1. Integration Test (`workflow_integration_test.ps1`)
**Goal:** Verifies the full end-to-end cycle (Writer → Redis → Reader).
* **Simulates:** A "Live Fire" attack scenario (5x SSH Brute Force + 3x Web Scans).
* **Validates:**
    * **API Rate Limits:** Forces a 120s wait to ensure the pipeline respects the VirusTotal 15s throttle.
    * **Data Hand-off:** Verifies `rules:5710` (Metadata) and `stats:5710:count` (Metrics) exist in Redis before the report runs.
    * **Cleanup:** Confirms counters are reset to `0` after the report is generated.

### 2. Ingestion Unit Test (`workflow_A_test.ps1`)
**Goal:** Stress tests the Writer's defense mechanisms.
* **Scenario 1: Deduplication:** Pushes duplicate alerts instantly; verifies only *one* Redis Lock is created.
* **Scenario 2: DLQ (Dead Letter Queue):** Pushes broken JSON (`{"broken":"json"}`); verifies it routes to `wazuh:errors` instead of crashing the pipeline.

### 3. Reporting Unit Test (`workflow_C_test.ps1`)
**Goal:** Validates the Reporter's math and error handling (Independent of Workflow A).
* **Mock Injection:** Manually injects a dirty state (`[5710, 6001]` index + metadata) directly into Redis.
* **Atomic Reset Check:** Verifies that reading a value resets it to `0`.
* **Resilience:** Injects corrupt indices (`"oops-not-json"`) to prove the engine fails gracefully without sending broken reports.

---

## 🚀 Usage Guide

### Prerequisites
* **n8n:** Workflows must be active.
* **Redis:** Must be accessible via Docker (`redis-cli`).
* **PowerShell 7** (Windows) or **Bash** (Linux/Mac).

### Running Tests
**Option A: PowerShell (Recommended for Windows)**
```powershell
# 1. Test Ingestion Logic
./workflow_A_test.ps1

# 2. Test Reporting Logic (Isolated)
./workflow_C_test.ps1

# 3. Test Full Pipeline (Slow - 2 Mins)
./workflow_integration_test.ps1

Option B: Bash (Linux/Mac/WSL)

Bash

chmod +x *.sh
./workflow_integration_test.sh
🛠️ Operational Troubleshooting
Symptom: "Active Rules: 4" (Duplicates)
Cause: The index:active_rules list contains duplicate IDs (e.g., [5710, 5710]).

Fix: The Compile Report node includes a Deduplication Set logic that filters these out automatically.

Verification: Run workflow_C_test.ps1 to confirm the report shows "Active Rules: 2" even if Redis is dirty.

Symptom: "Unknown Alert" (Vol: 0)
Cause: The "Broken Chain." Hydrate Context node passed metadata but dropped the count from the previous node.

Fix: The Generate Row node uses a "Look Back" strategy:

JavaScript

// Reaches back to Atomic Fetch node to grab the count directly
const fetchNode = $('Atomic Fetch and Reset').item;
Symptom: "Database state incomplete" (Test Failure)
Cause: Workflow A is processing alerts but failing to write metadata to rules:ID.

Check: Ensure Workflow A's Redis Write node is using the key pattern rules:{{ $json.rule.id }} and not stats:....

📊 Analytics Definitions
The report includes custom metrics calculated in the Compile Report node:

Severity: Counts of alerts by level (🔴 Critical, 🟡 High, ⚪ Low).

Intensity: Average severity level of all active threats (0-15 scale).

Top Threat: The single rule ID with the highest volume count.

1. 🖐️ Workflow B: The State Modifier ("The Hand")
While Workflows A and C handle the continuous flow of data, Workflow B handles the flow of intent. It is an event-driven engine triggered solely by human interaction (Slack Buttons), transforming decisions into infrastructure actions.

🏗️ Architecture Overview
Workflow B sits outside the ingestion loop. It does not process logs; it processes decisions.

Trigger: Slack Webhook (POST request from block_actions).

Role: Updates the "World State" in Redis so that Workflow A (Ingestion) and the Python Worker (Response) know how to behave.

⚡ Operational Logic
Input Parsing: Decodes the application/x-www-form-urlencoded payload from Slack to identify the action_id, user, and the pipe-delimited value (action|target).

Path 1: The "False Positive" (Whitelist)

Action: Writes a volatile key to Redis.

Key Schema: whitelist:{{ip}} (e.g., whitelist:192.168.1.50).

TTL: Defaults to 7 days (604,800s) to prevent permanent security holes.

Effect: Workflow A will immediately drop future alerts from this IP.

Path 2: The "Kill Switch" (Isolate)

Action: Pushes a task object to the Action Queue.

Key Schema: wazuh:actions (Redis List).

Payload: {"task": "isolate", "target": "{{agent_id}}", "auth": "User"}.

Effect: The Python Worker pops this item and executes the VBoxManage or Cloud API command.

Updated Test Suite Documentation
The test suite has been upgraded to support Environment Variable (.env) loading for secure configuration management.

📂 Configuration (.env)
All tests now look for a .env file in the project root to load secrets dynamically.

Code snippet

REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASS=your_secure_password
N8N_WEBHOOK_URL=http://your-n8n-instance/webhook/wazuh-response
4. Interaction Unit Test (workflow_B_test.ps1)
Goal: Verifies that human decisions accurately alter the pipeline's behavior without requiring manual clicks in Slack.

Setup: Automatically loads N8N_WEBHOOK_URL and REDIS_PASS from .env.

Scenario 1: The Whitelist Effect

Injection: Simulates a Slack payload with value="ignore|10.50.50.5".

Validation: Checks EXISTS whitelist:10.50.50.5 in Redis.

Scenario 2: The Action Queue

Injection: Simulates a Slack payload with value="isolate|Desktop-Agent-01".

Validation: Pops the last item from wazuh:actions and verifies the JSON structure matches the worker's expectations.

🚀 Usage Guide (Updated)
Prerequisites

n8n: All 3 workflows (A, B, C) must be active.

Python Worker: Must be running (python host_worker_v2.py) to consume isolation tasks.

Config: A .env file must be present.
