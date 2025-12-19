# Warden SOAR Lab - Setup Guide

This guide provides environment-agnostic instructions for deploying Warden from scratch. I've structured it to show both **what** to configure and **why** each step matters from an architectural perspective.

---

## 🧰 Prerequisites

### 💻 Hardware Requirements

- **Host machine:** 16 GB RAM minimum, 100 GB free disk space
- **CPU:** 4+ cores with virtualization support (VT-x/AMD-V enabled in BIOS)

### 🧪 Software Requirements

- **Hypervisor:** VirtualBox 7.0+ (or VMware Workstation, Hyper-V with adapter adjustments)
- **Container runtime:** Docker Desktop (Windows/Mac) or Docker Engine (Linux)
- **Operating systems:**
  - Ubuntu Server 24.04 LTS ISO
  - Parrot OS Security Edition ISO (or Kali Linux as alternative)
- **Slack workspace:** Admin access to create apps and configure webhooks

### ⭐ Optional

- **Domain name:** For persistent Cloudflare Named Tunnel (~$10/year)
- **VirusTotal API key:** For threat intelligence enrichment

---

## 🚦 Phase 1: Host Logic Layer (n8n + Redis)

Deploy the workflow engine and message broker on your host machine using Docker Compose.

### 1.1 Create Project Structure

```bash
mkdir warden-soar && cd warden-soar
```

### 1.2 Configure Environment

Create `.env` from the example:

```bash
cp .env.example .env
nano .env # or use your preferred editor
```

**Critical configurations:**

- **`REDIS_PASSWORD`:** Generate strong password:

```bash
openssl rand -base64 32
```

- **`HOST_IP`:** Find your host-only adapter IP:

```bash
# Windows
ipconfig | findstr "VirtualBox"

# Linux/Mac
ip a | grep vboxnet
```

Typically: `192.168.56.1`

- **`N8N_HOST`:**
  - For local testing: `localhost`
  - For Cloudflare Quick Tunnel: Leave blank initially (configure after tunnel setup)

- **`WEBHOOK_URL`:**
  - Local: `http://localhost:5678`
  - Cloudflare: `https://<your-tunnel-subdomain>.trycloudflare.com`

### 1.3 Start Services

```bash
docker-compose up -d
```

### 1.4 Verify Deployment

Check container status:

```bash
docker-compose ps
```

Watch n8n startup logs:

```bash
docker-compose logs -f n8n
```

Test Redis connectivity:

```bash
docker exec -it warden-redis redis-cli -a "YOUR_PASSWORD" ping
# Expected output: PONG
```

Access n8n at **http://localhost:5678** and complete the initial setup wizard.

---

## 🛡️ Phase 2: Control Plane VM (Wazuh Manager)

Deploy Ubuntu Server with custom storage and networking to host the Wazuh manager, indexer, and dashboard.

### 2.1 VM Creation

Create a new VM in VirtualBox:

- **Name:** `Warden-Manager`
- **Type:** Linux, Ubuntu (64-bit)
- **Memory:** 4096 MB minimum
- **CPU:** 2 cores
- **Disk:** 60 GB (dynamically allocated VDI)

**Network adapters:**
1. **Adapter 1:** NAT (for internet access)
2. **Adapter 2:** Host-only Adapter (`vboxnet0`)

### 2.2 OS Installation – Storage Configuration

> ⚠️ **Critical step**: Prevents "no space left on device" failures during Wazuh upgrades.

During Ubuntu installation, when you reach the storage configuration screen:

1. Select **"Custom storage layout"**
2. Navigate to the `ubuntu-lv` logical volume
3. **Edit** the size to use **100% of available space** (approximately 58 GB), not the default ~29 GB

**Why this matters:** By default, Ubuntu allocates only 50% of disk space to the root partition, reserving the rest for future snapshots. Wazuh's installation and log extraction will exceed 29 GB, causing crashes mid-upgrade.

### 2.3 Network Configuration

After OS installation, configure static IPs for the host-only adapter.

#### Identify Interfaces

```bash
ip a
```

You'll see:
- `lo` (loopback)
- `enp0s3` (NAT adapter, typically `10.0.2.15`)
- `enp0s8` (host-only adapter, no IP yet)

#### Configure Netplan

```bash
sudo nano /etc/netplan/00-installer-config.yaml
```

Paste this configuration:

```yaml
network:
  ethernets:
    enp0s3:
      dhcp4: true
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
    enp0s8:
      dhcp4: false
      addresses:
        - 192.168.56.111/24
  version: 2
```

**Why explicit nameservers?** Static IP configuration can remove DHCP-provided DNS, breaking internet connectivity even though the NAT adapter is active.

#### Apply and Verify

```bash
sudo netplan apply
ip a # Confirm enp0s8 shows 192.168.56.111/24
```

### 2.4 Connectivity Checkpoint ✅

Before installing Wazuh, verify all network paths:

From **Ubuntu VM**:

```bash
ping 192.168.56.1   # Host machine
ping google.com     # Internet via NAT
```

From **host machine** (Windows PowerShell or Linux terminal):

```bash
ping 192.168.56.111 # Ubuntu VM
```

All three paths must succeed before proceeding.

### 2.5 Wazuh Installation

Use the automated installer to establish a known-good baseline quickly:

```bash
curl -sO https://packages.wazuh.com/4.9/wazuh-install.sh
sudo bash ./wazuh-install.sh -a
```

> 💾 **Save the admin password** displayed at the end.

**Why the automated script?** In production environments, automation (Ansible, Terraform, scripts) is preferred over manual configuration. The `-a` flag is closer to Infrastructure as Code and guarantees a stable baseline. The portfolio value is in the **custom pipeline**, not in hand-building OpenSearch clusters.

### 2.6 Upgrade to Wazuh 4.10 (if needed)

If your agent auto-installs a newer version (4.10), upgrade the manager to match:

```bash
sudo apt update
sudo apt upgrade -y wazuh-manager wazuh-indexer wazuh-dashboard
```

**Common upgrade issues encountered:**

#### Issue 1: dpkg Lock Files

```bash
sudo fuser -vki /var/lib/dpkg/lock-frontend
sudo rm /var/lib/dpkg/lock-frontend
sudo rm /var/lib/dpkg/lock
sudo dpkg --configure -a
```

#### Issue 2: Wazuh Indexer Startup Timeout

The Java-based indexer may exceed systemd's 90-second timeout on VMs with limited I/O:

```bash
sudo mkdir -p /etc/systemd/system/wazuh-indexer.service.d/
echo -e "[Service]
TimeoutStartSec=600"   | sudo tee /etc/systemd/system/wazuh-indexer.service.d/startup-timeout.conf
sudo systemctl daemon-reload
sudo systemctl start wazuh-indexer
```

#### Issue 3: Dashboard Certificate Name Drift

If the dashboard crashes after upgrade:

```bash
cd /etc/wazuh-dashboard/certs/
sudo mv wazuh-dashboard.pem dashboard.pem
sudo mv wazuh-dashboard-key.pem dashboard-key.pem
sudo systemctl restart wazuh-dashboard
```

See **RUNBOOK.md** for complete troubleshooting details (to be added).

### 2.7 Firewall Configuration

Open required ports:

```bash
sudo ufw allow 443/tcp   # Dashboard (HTTPS)
sudo ufw allow 1514/tcp  # Agent log transmission
sudo ufw allow 1515/tcp  # Agent enrollment
sudo ufw reload
```

Verify dashboard binding:

```bash
sudo ss -tuln | grep 443
```

Must show: `0.0.0.0:443` or `*:443`.

If showing `127.0.0.1:443`:

```bash
sudo nano /etc/wazuh-dashboard/opensearch_dashboards.yml
# Set:
server.host: "0.0.0.0"

sudo systemctl restart wazuh-dashboard
```

Access dashboard at **https://192.168.56.111** (accept self-signed certificate warning).

### 2.8 Python Integration Bridge

Install the integration that pushes Wazuh alerts into Redis.

#### Create Virtual Environment

```bash
sudo apt install python3-pip python3-venv -y
sudo python3 -m venv /var/ossec/integrations/.venv
```

#### Install Dependencies

```bash
sudo /var/ossec/integrations/.venv/bin/pip install redis requests python-dotenv
```

#### Deploy Integration Script

Copy your `wazuh-redis.py` to `/var/ossec/integrations/` and configure Wazuh to call it on alerts.

Edit `/var/ossec/etc/ossec.conf` and add:

```xml
<integration>
  <name>wazuh-redis</name>
  <hook_url>http://192.168.56.1:6379</hook_url>
  <level>8</level>
  <alert_format>json</alert_format>
</integration>
```

Restart manager:

```bash
sudo systemctl restart wazuh-manager
```

---

## 🖥️ Phase 3: Agent VM (Monitored Endpoint)

Deploy Parrot OS as the monitored system with dual-NIC configuration.

### 3.1 VM Creation

Create VM in VirtualBox:

- **Name:** `Warden-Agent`
- **Type:** Linux, Debian (64-bit)
- **Memory:** 2048 MB
- **CPU:** 2 cores
- **Disk:** 40 GB
- **Network:** NAT + Host-only (same as manager)

### 3.2 Network Configuration

#### GUI Method (Network Manager)

- Right-click network icon → **Edit Connections**
- Select **Wired connection 2** (host-only adapter)
- Go to **IPv4 Settings** tab:
  - Method: **Manual**
  - Address: `192.168.56.110`
  - Netmask: `24` (or `255.255.255.0`)
  - Gateway: *(leave empty – internet traffic uses NAT adapter)*
- Click **Save**

#### CLI Method

```bash
sudo nmcli connection modify "Wired connection 2" ipv4.addresses 192.168.56.110/24
sudo nmcli connection modify "Wired connection 2" ipv4.method manual
sudo nmcli connection modify "Wired connection 2" ipv4.gateway ""
sudo nmcli connection up "Wired connection 2"
```

### 3.3 Agent Installation

```bash
# Add Wazuh repository
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH   | sudo gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import
sudo chmod 644 /usr/share/keyrings/wazuh.gpg

echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main"   | sudo tee -a /etc/apt/sources.list.d/wazuh.list

sudo apt update

# Install agent with manager IP
sudo WAZUH_MANAGER="192.168.56.111" apt install wazuh-agent -y

# Enable and start
sudo systemctl enable wazuh-agent
sudo systemctl start wazuh-agent
```

### 3.4 Verify Connection

```bash
sudo systemctl status wazuh-agent
grep -i "connected" /var/ossec/logs/ossec.log
# Expected: "Connected to server 192.168.56.111"
```

On the manager dashboard (**https://192.168.56.111**), verify **Total Agents** shows 1 and the agent status is **Active**.

### 3.5 Detection Tuning

Edit `/var/ossec/etc/ossec.conf` on the agent to enable real-time monitoring:

```xml
<syscheck>
  <!-- Real-time for critical paths (sub-second MTTD) -->
  <directories realtime="yes">/etc,/usr/bin,/usr/sbin</directories>

  <!-- Monitored with faster polling -->
  <directories check_all="yes" report_changes="yes">/root</directories>

  <!-- Ignored to reduce noise -->
  <ignore>/tmp</ignore>
  <ignore>/var/cache</ignore>
  <ignore>/var/log</ignore>

  <!-- Scan every 5 minutes instead of 12 hours -->
  <frequency>300</frequency>
</syscheck>
```

Restart agent:

```bash
sudo systemctl restart wazuh-agent
```

---

## 🔁 Phase 4: n8n Workflow Deployment

### 4.1 Configure Credentials

In n8n (**http://localhost:5678**):

**Redis credential:**

- Host: `192.168.56.1`
- Port: `6379`
- Password: (from `.env`)

**Slack credential:**

- Create Slack app with `chat:write` scope
- Enable **Interactive Components** (configure webhook URL after tunnel setup)
- Add OAuth token to n8n

**VirusTotal credential (optional):**

- Auth type: **HTTP Header Auth**
- Name: `x-apikey`
- Value: *Your API key*

### 4.2 Import Workflows

- Navigate to **Workflows → Import from File**
- Import all JSON files from `workflow/` directory
- Activate each workflow after import

### 4.3 Configure Cloudflare Tunnel (for Slack webhooks)

#### Quick Tunnel (Proof of Concept)

```bash
# Install cloudflared
# macOS:
brew install cloudflare/cloudflare/cloudflared

# Linux:
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
sudo dpkg -i cloudflared.deb

# Start tunnel
cloudflared tunnel --url http://localhost:5678
```

Copy the generated `trycloudflare.com` URL and:

- Update `N8N_HOST` and `WEBHOOK_URL` in `.env`
- Restart n8n:

```bash
docker-compose restart n8n
```

- Configure the URL in Slack app settings (**Interactive Components**)

#### Named Tunnel (Production)

For permanent URLs with your own domain, follow Cloudflare Tunnel documentation to:

- Create a **Named Tunnel**
- Map it to a subdomain (e.g., `soar.mydomain.com`)
- Point DNS (CNAME) to Cloudflare's tunnel endpoint

---

## 🪟 Phase 5: Windows Worker Deployment

### 5.1 Install Dependencies

```bash
cd workers/
pip install -r requirements.txt
```

### 5.2 Configure VM Mapping

Edit `vm_config.json`:

```json
{
  "vm_mapping": {
    "001": "Warden-Agent",
    "warden-agent": "Warden-Agent"
  }
}
```

Map Wazuh agent IDs/names to VirtualBox VM names.

### 5.3 Run Worker

```bash
python host_worker.py
```

The worker will connect to Redis and begin consuming commands from `wazuh:actions`.

### 5.4 Verify Heartbeat

```bash
docker exec -it warden-redis redis-cli -a "YOUR_PASSWORD" get worker:heartbeat
# Should return recent Unix timestamp
```

---

## ✅ Verification & Testing

### End-to-End Test

Trigger alert on **agent VM**:

```bash
# High-severity action
echo "test" | sudo tee /etc/test-warden-alert
```

Verify flow:

1. Check n8n execution logs
2. Confirm Slack message received
3. Click **"Isolate"** button
4. Verify worker executes `VBoxManage` command

Check analytics:

- Wait for hourly workflow (or manually execute **Workflow C**)
- Verify SitRep in Slack

### Troubleshooting

If the pipeline doesn't work:

**Check Redis queue depth:**

```bash
docker exec -it warden-redis redis-cli -a "PASSWORD" LLEN wazuh:alerts
```

**Review n8n logs:**

```bash
docker-compose logs -f n8n
```

**Verify agent connectivity:**

```bash
sudo systemctl status wazuh-agent
grep -i "connected" /var/ossec/logs/ossec.log
```

---

*Warden Setup Guide – built to highlight both implementation detail and architectural intent.*
