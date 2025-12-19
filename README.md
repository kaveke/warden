# 🛡️ Warden

> **Real-time security orchestration and automated response**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/docker-ready-brightgreen.svg)](docker-compose.yml)
[![Python](https://img.shields.io/badge/python-3.9+-blue.svg)](requirements.txt)
[![Security](https://img.shields.io/badge/security-SOAR-red.svg)](#architecture)
[![Status](https://img.shields.io/badge/status-production--ready-success.svg)](#quick-start)

Warden is an event-driven SOAR (Security Orchestration, Automation and Response) pipeline that achieves **zero-latency threat detection and response** by decoupling security event ingestion from automated remediation. Built using Wazuh, n8n, Redis, and VirtualBox, it demonstrates production-grade architecture patterns including stateless workflows, mutex-protected automation, and resilient external connectivity.

---

## 🎯 Overview

Traditional security labs rely on polling mechanisms (cron jobs, scheduled queries) that introduce **minutes or hours of latency** between compromise and response. Warden eliminates this delay by streaming security events through a Redis-backed queue, enabling **sub-second detection-to-response workflows**.

### ⚡ Key Features

- **🚀 Zero-latency pipeline:** Wazuh agent events push instantly into Redis; n8n workflows consume and process in real time
- **🌐 Production network design:** Dual-NIC architecture separates control plane (Wazuh/n8n/Redis) from data plane (internet access)
- **♻️ Stateless workflows:** n8n workflows complete and die rather than holding state, surviving restarts without breaking in-flight approvals
- **👤 Human-in-the-loop:** Slack interactive messages drive analyst decisions with direct deep links into the Wazuh dashboard
- **🔒 Safe remediation:** Python worker implements mutex locks, input validation, and allowlisted actions for VirtualBox automation
- **🔗 Stable connectivity:** Cloudflare Tunnel for webhook ingress after validating and discarding unstable alternatives (localtunnel, ngrok free tier)

---

## 🏗️ Architecture

### Logical Tiers

| Component | Technology | Responsibility |
|-----------|-----------|----------------|
| **🔍 Detection** | Wazuh agent (Parrot OS) | File integrity monitoring, security telemetry |
| **🎛️ Control Plane** | Wazuh manager (Ubuntu Server) | Event correlation, analysis, dashboard |
| **🌉 Bridge** | Python integration | Push alerts from Wazuh into Redis (`wazuh:alerts`) |
| **⚙️ Logic Layer** | n8n + Redis (Docker) | Deduplication, enrichment, Slack UX, analytics |
| **🔧 Execution** | Python worker (Windows) | Consume commands from Redis, execute VBoxManage |

### 🌍 Network Topology

- **Host:** Windows with Docker Desktop
- **VMs:** Ubuntu Server (192.168.56.111) and Parrot OS (192.168.56.110)
- **Dual adapters per VM:**
  - NAT for internet access
  - Host-only (192.168.56.0/24) for control plane isolation
- **Tunnel:** Cloudflare Tunnel exposes n8n webhooks to Slack via outbound-only encrypted connection

### 🔄 Data Flow

1. **Detection:** Wazuh agent detects file modification or security event
2. **Ingestion:** Wazuh manager analyzes event; Python bridge pushes JSON to `wazuh:alerts`
3. **Processing:** n8n Workflow A (cyclic consumer) pops alert, normalizes, deduplicates, enriches via VirusTotal, and sends Slack notification
4. **Decision:** Analyst clicks "Isolate" or "Ignore" button in Slack
5. **Remediation:** n8n Workflow B validates request and pushes command to `wazuh:actions`
6. **Execution:** Python worker pops command, acquires Redis mutex lock, and executes `VBoxManage` snapshot revert or isolation
7. **Reporting:** n8n Workflow C runs hourly, aggregates attack counts, and sends Security SitRep to Slack

**Full architecture documentation:** [ARCHITECTURE.md](ARCHITECTURE.md)

---

## Quick Start

### Prerequisites

- Docker Desktop (Windows/Mac) or Docker Engine (Linux)
- VirtualBox 7.0+
- 16 GB RAM, 100 GB free disk space
- Slack workspace (admin access for app creation)
- (Optional) Domain for persistent Cloudflare Tunnel

### 1️⃣ Clone and Configure

```bash
git clone https://github.com/kaveke/warden.git
cd warden-soar
cp .env.example .env
```

Edit `.env` and configure:
- `REDIS_PASSWORD` (generate with `openssl rand -base64 32`)
- `HOST_IP` (your VirtualBox host-only adapter IP)
- `WAZUH_URL` (will be `https://192.168.56.111` after VM setup)

### 2️⃣ Start Docker Stack

```bash
docker-compose up -d
docker-compose logs -f n8n # Watch for successful startup
```

Access n8n at http://localhost:5678 and complete the setup wizard.

### 3️⃣ Deploy VMs and Configure Wazuh

Follow the comprehensive guide in [SETUP.md](SETUP.md) to:
- Provision Ubuntu Server (Wazuh manager) and Parrot OS (agent)
- Configure dual-NIC networking with static IPs
- Install and upgrade Wazuh to version 4.10
- Deploy the Python integration bridge

### 4️⃣ Import Workflows

1. In n8n, navigate to **Workflows** → **Import from File**
2. Import comprehensive JSON file from the `workflow/` directory
3. Configure credentials:
   - **Redis:** Host: `192.168.56.1`, Port: `6379`, Password from `.env`
   - **Slack:** OAuth token and signing secret from Slack app
   - **VirusTotal (optional):** API key for threat intelligence enrichment

### 5️⃣ Deploy Worker

```bash
cd workers/
pip install -r requirements.txt
python host_worker.py
```

The worker will connect to Redis and begin consuming remediation commands.

---

## Documentation

| Document | Description |
|----------|-------------|
| **[ARCHITECTURE.md](ARCHITECTURE.md)** | Deep dive into design decisions, failure modes, and tunnel evolution |
| **[SETUP.md](SETUP.md)** | Environment-agnostic deployment guide with step-by-step VM configuration |
| **[RUNBOOK.md](RUNBOOK.md)** | Operational troubleshooting guide documenting real issues encountered and resolved *(Coming soon)* |

---

## Testing

Warden includes comprehensive test suites for validating workflows independently:

```powershell
# Test alert ingestion (Workflow A)
./tests/workflow_A_test.ps1

# Test Slack interaction handling (Workflow B)
./tests/workflow_B_test.ps1

# Test analytics aggregation (Workflow C)
./tests/workflow_C_test.ps1

# End-to-end integration test (workflow A and C -- B to be integrated)
./tests/workflow_integration_test.sh
```

**See [tests/README.md](tests/README.md) for detailed testing documentation.**

---

## Design Highlights

### Why This Architecture?

**🔄 Stateless workflows:** Early iterations used n8n's Wait node to pause execution while awaiting Slack responses. This created a critical failure mode: restarting n8n killed all in-flight approvals. The current design stores state in Slack message IDs, allowing workflows to complete immediately and resume only when the analyst clicks a button.

**🌐 Cloudflare Tunnel reliability:** After encountering data truncation with ngrok's free tier and unpredictable disconnections with localtunnel, I deployed Cloudflare Tunnel for production-grade stability. Quick Tunnels provide temporary URLs for testing; Named Tunnels with custom domains offer permanent webhook endpoints.

**🔐 Redis mutex locks:** During brute-force simulations, concurrent alert processing triggered simultaneous VBoxManage snapshot operations on the same VM, causing lock errors. The worker now implements per-VM mutex locks using Redis keys with TTL, preventing race conditions.

**⏱️ Real-time FIM tuning:** Default Wazuh configurations scan files every 12 hours for compliance purposes. I enabled real-time monitoring via kernel inotify on critical paths (`/etc`, `/usr/bin`) while filtering noisy directories, achieving sub-second mean time to detect (MTTD).

**Full design rationale and lessons learned:** [ARCHITECTURE.md](ARCHITECTURE.md)

---

## Known Limitations

*Explicitly documented for transparency:*

- **n8n database:** Currently using SQLite; suitable for this lab but not for high-concurrency production workloads
- **Redis HA (High Availability):** Single instance without replication or persistence tuning
- **Tunnel security:** Cloudflare Tunnel is stable but adds an external dependency; production deployments should consider direct cloud hosting or VPN

📘 **See [ARCHITECTURE.md](ARCHITECTURE.md) for migration paths to production-grade configurations.**

---

## 🤝 Contributing

This is a portfolio/demonstration project, but suggestions and improvements are welcome:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Commit your changes with clear messages
4. Push and open a pull request

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 🙏 Acknowledgments

- **Wazuh** for the open-source SIEM/XDR platform
- **n8n** for the workflow automation engine
- **Cloudflare** for stable tunnel infrastructure
- Security community resources that informed architecture decisions and troubleshooting approaches

---

**🛡️ Built by [Kaveke](https://github.com/kaveke)**

*Demonstrating production-grade security automation architecture*
