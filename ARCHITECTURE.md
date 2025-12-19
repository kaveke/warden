# 🏗️ System Architecture

This document describes the design and technical decisions behind the event-driven SOAR pipeline I built to demonstrate real-time security automation and threat response capabilities.

---

## 🎯 Design Philosophy

I designed this lab to showcase **production-grade architectural thinking** rather than simply following tutorials. The system separates concerns across network boundaries, implements defensive coding patterns, and explicitly handles failure modes that would appear in real security operations.

---

## 📊 High-Level Components

The architecture divides into four logical tiers:

### 🔍 Detection Layer (Parrot OS)

I deployed a Wazuh agent on Parrot OS configured for **low-latency file integrity monitoring**. Rather than using the default 12-hour scan cycle, I enabled real-time monitoring via kernel `inotify` on critical paths like `/etc` and `/usr/bin`, while tuning out noisy directories to reduce false positives.

**Achievement:** This configuration achieves **sub-second detection** for persistence mechanisms while maintaining system stability under normal load.

### 🎛️ Control Plane (Ubuntu Server)

The Wazuh manager, indexer, and dashboard run on Ubuntu Server. I upgraded this stack to **version 4.10** to maintain version parity with the agent, which required troubleshooting several infrastructure issues including:

- LVM capacity planning
- systemd timeout tuning
- Certificate name drift post-upgrade

**Custom Integration:** I wrote a Python integration that bridges Wazuh alerts into Redis. This integration runs in an isolated virtual environment to avoid breaking system-level Python dependencies—a deliberate choice to prevent the "works on my machine but breaks apt" scenario common with `--break-system-packages`.

### ⚙️ Logic Layer (n8n + Redis on Docker)

I implemented three **stateless n8n workflows** backed by Redis as both a message broker and state store:

#### 🔄 Workflow A – Alert Dispatcher

This workflow implements a cyclic consumption pattern that drains the `wazuh:alerts` queue until empty. Key features I built:

- **Payload normalization** to handle inconsistent JSON structures from Wazuh
- **IP-based allowlisting** with Redis key lookups
- **Deduplication** using a "keys as sets" pattern (e.g., `lock:alert:<rule_id>` with 15-minute TTL)
- **Just-in-time rate limiting** for VirusTotal enrichment (delays only applied before API calls, not during internal logic)
- **Rule metadata caching** to support analytics workflows
- **Private IP filtering** to avoid wasting API quota on RFC1918 addresses

The workflow sends Slack notifications with **deep links** back into the Wazuh dashboard, filtering by rule ID and timestamp.

#### 🔨 Workflow B – Remediation Handler

This workflow processes Slack interactive webhook payloads. I implemented:

- **Signature verification** and strict input validation to prevent command injection
- **Normalized actions** into a minimal JSON schema before pushing to `wazuh:actions`

**Design decision:** I deliberately chose a **stateless design** over n8n's Wait node so that restarting the Docker stack doesn't kill in-flight approvals.

#### 📊 Workflow C – Security SitRep Generator

This hourly workflow:

- Reads the centralized `index:active_rules` key maintained in Workflow A
- Fetches attack counts using Redis's GetSet operation (atomically reading and resetting counters)
- Compiles a formatted Slack report

**Implementation evolution:** I switched from Block Kit JSON to Markdown after encountering persistent "bad control character" errors and poor mobile UX. The current implementation calculates severity buckets, identifies top threats, and applies a traffic-light status indicator.

### 🔧 Execution Layer (Windows Python Worker)

I wrote a Python worker process on the Windows host that consumes commands from `wazuh:actions` and executes VirtualBox control plane operations via `VBoxManage`.

#### 🛡️ Critical Design Decisions

| Feature | Implementation | Rationale |
|---------|----------------|-----------|
| **🔐 Mutex locking** | Sets Redis key `lock:vm:parrot` with 30-second expiry | Prevents concurrent operations during alert storms |
| **✅ Input validation** | Strict allowlist for commands and VM identifiers | Prevents command injection attacks |
| **💓 Heartbeat monitoring** | Updates `worker:heartbeat` every 60 seconds | Enables detection of silent failures via n8n monitor |

**Architecture decision:** I chose not to run this inside the Docker network to respect isolation boundaries—the worker deliberately sits at the hypervisor level where it needs to be.

---

## 🌐 Network Topology

I implemented a **dual-NIC strategy** to separate the control plane from internet traffic:

| Host | NAT Adapter (Internet) | Host-Only Adapter (Control) |
|------|------------------------|----------------------------|
| **Windows** | Native NIC | 192.168.56.1 |
| **Ubuntu Server** | DHCP via enp0s3 | 192.168.56.111/24 (static) |
| **Parrot OS** | DHCP via enp0s3 | 192.168.56.110/24 (static) |

**Benefits:** This design eliminates port-forwarding complexity while ensuring the Wazuh dashboard, n8n, and Redis are directly reachable from the host without exposing them to the broader network.

---

## 🌍 External Connectivity: The Tunnel Evolution

Exposing n8n to Slack required solving a critical challenge: **how to provide a stable, public HTTPS endpoint for webhook callbacks** without opening firewall ports or exposing my home IP.

### 🧪 Initial Attempts

#### ❌ Localhost Testing

I started with local testing using `http://localhost:5678`, which validated the workflow logic but couldn't receive external webhooks from Slack.

#### ❌ ngrok (Failed)

I attempted to use ngrok's free tier, which provides permanent subdomains on `ngrok-free.dev`. While the tunnel established successfully, I encountered a **critical stability issue**:

- Large JavaScript bundles (like n8n's main application code) were **truncated mid-transfer**
- Caused `Uncaught SyntaxError: Unexpected end of input` errors
- The free tier's network priority appeared insufficient for serving the full n8n UI reliably

#### ❌ localtunnel (Failed)

I then switched to localtunnel as a zero-cost alternative. Despite implementing automated reconnection logic with `restart: always` and retry loops, the service proved **too unstable for production use**—tunnels would drop unpredictably, breaking Slack's webhook delivery.

### ✅ Final Solution: Cloudflare Tunnel

After evaluating the failure modes of community tunneling services, I deployed **Cloudflare Tunnel** (`cloudflared`) as the production-grade solution.

#### 🏆 Why Cloudflare Tunnel Won

| Feature | Benefit |
|---------|---------|
| **🔒 Stability** | Leverages Cloudflare's global edge network rather than volunteer-operated relay servers |
| **💰 Zero cost** | Free for webhook use cases; only requires a domain (~$10/year) for persistent URLs |
| **🔐 Automatic TLS** | Cloudflare handles certificate management and HTTPS termination at the edge |
| **🚪 No inbound ports** | Tunnel operates via outbound-only connections, preserving home network security |
| **📦 Process isolation** | Runs as a dedicated container in the Docker stack, cleanly separated from n8n |

#### 🔧 Implementation

I deployed `cloudflared` as a Docker service alongside n8n and Redis:

**Phase 1 - Proof of Concept:**
Used Cloudflare's "Quick Tunnel" feature, which generates temporary `trycloudflare.com` URLs without requiring DNS configuration. This allowed immediate validation of the Slack integration.

**Phase 2 - Production:**
The architecture upgrades to a **Named Tunnel** with a custom domain (e.g., `soar.mydomain.com`), providing a permanent webhook URL that survives container restarts.

#### 🧪 Testing Validation

Using `webhook.site` as an external diagnostic endpoint, I confirmed that:

1. ✅ Slack's interactive webhooks successfully reached Cloudflare's edge
2. ❌ Initially failed to reach n8n due to **Windows Firewall blocking** the `cloudflared → n8n` connection on port 5678
3. ✅ After creating a process-specific firewall rule allowing `cloudflared.exe` to communicate with the Docker bridge network, the full request path stabilized

#### 🔄 Final Traffic Flow

```
Slack → Cloudflare Edge → cloudflared Container → n8n Container
```

With automatic reconnection and health monitoring via `cloudflared`'s built-in keepalive.

---

## 🔄 Data Flow

The complete detection-to-response path:

1. **🎯 Detection:** Wazuh agent detects file modification or security event
2. **📊 Analysis:** Manager analyzes and correlates, emitting an alert
3. **📥 Ingestion:** Python integration pushes JSON to `wazuh:alerts` (Redis list)
4. **⚡ Processing:** n8n Workflow A pops alert, normalizes, deduplicates, enriches, and sends Slack message
5. **💬 Decision:** Analyst clicks button in Slack
6. **✅ Validation:** Workflow B receives webhook, validates signature, and pushes command to `wazuh:actions`
7. **🔨 Execution:** Python worker pops command, acquires mutex lock, and executes `VBoxManage snapshot ... restore`

**Reliability:** Each stage logs errors and implements timeout/retry logic appropriate to its role.

---

## 🛠️ Technology Choices

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **🔍 Detection** | Wazuh 4.10 | Open-source SIEM with strong FIM and agent architecture |
| **📨 Message Broker** | Redis | Fast in-memory store with native list operations and TTL support |
| **⚙️ Orchestration** | n8n | Visual workflow builder with Redis/Slack integrations and webhook support |
| **💻 Virtualization** | VirtualBox | Free, scriptable via VBoxManage, runs on Windows host |
| **💬 Notification** | Slack | Familiar SOC interface with interactive message support |

**Philosophy:** I explicitly avoided cloud services to keep the lab portable and to demonstrate infrastructure-level skills rather than managed-service configuration.

---

## ⚠️ Failure Modes and Mitigations

I documented these explicitly because they represent **real operational concerns**:

| Risk | Impact | Mitigation |
|------|--------|-----------|
| **🔴 Python bridge crash** | Alerts stop flowing despite active detection | Systemd restart policy (future); dead letter queue for retry |
| **🔴 Redis queue overflow** | Memory exhaustion during prolonged n8n downtime | Logical list capping; oldest items dropped beyond threshold |
| **🔴 Worker crash** | Commands queue but nothing executes | Heartbeat monitoring with Slack alerting |
| **🔴 Thundering herd** | Concurrent snapshot calls cause VirtualBox lock errors | Per-VM mutex using Redis keys with TTL |
| **🔴 Command injection** | Compromised Redis could execute arbitrary code | Strict allowlist validation; no shell execution |

---

## 🚧 Limitations and Future Work

I'm explicit about current constraints:

### Current Limitations

- **📊 n8n database:** Uses SQLite, suitable for this lab but not for high-concurrency production
- **💾 Redis HA:** Runs as a single instance without persistence tuning or replication
- **🌐 Slack connectivity:** Requires Cloudflare Tunnel without WAF or additional signature validation layers
- **📡 Alert scope:** Wazuh integration currently handles a curated subset of alert types

### 🚀 Production Migration Path

For a production deployment, I would implement:

| Component | Upgrade Path |
|-----------|--------------|
| **🗄️ n8n persistence** | Migrate to PostgreSQL for multi-instance support |
| **💾 Redis HA** | Implement Redis Sentinel for automatic failover |
| **📊 Observability** | Add structured logging with ELK stack |
| **🔒 Security** | Deploy tunnel behind reverse proxy with rate limiting and WAF |
| **📈 Scalability** | Kubernetes deployment with horizontal pod autoscaling |

---

<div align="center">

**🏗️ Architecture designed and implemented by [Kaveke](https://github.com/kaveke)**

*Demonstrating enterprise-grade security automation patterns in a lab environment*

</div>
