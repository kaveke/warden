# Operational Runbook: Deploying a Zero-Latency SOAR Lab

Building a high-performance SOAR (Security Orchestration, Automation, and Response) pipeline is as much about infrastructure resilience as it is about security logic. This runbook documents the "scar tissue"—the critical failures and hard-won solutions—encountered while deploying a Wazuh, n8n, and Redis-based automation stack.

---

## 1. Infrastructure: The Ground Game

The most frustrating failures happen before the first alert is even fired. These fixes prevent your environment from collapsing under the weight of its own data.

### The LVM Allocation Trap

**Problem**  
The Ubuntu VM reports `No space left on device` even though the virtual disk is 60 GB.

**Root Cause**  
Ubuntu Server's default installer allocates only ~50% of the volume group to the root logical volume (`ubuntu-lv`), leaving the rest unused for potential snapshots. Data-heavy services like the Wazuh Indexer (OpenSearch) will exhaust this small root partition quickly.

**Fix**

```bash
# Claim 100% of the available volume group
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv

# Verify the new size
df -h
```

### Systemd Timeout Tuning

**Problem**  
`wazuh-indexer.service` fails to start with a "Job for wazuh-indexer.service failed because a timeout was exceeded" error.

**Insight**  
Java-based applications (OpenSearch/Elasticsearch) have heavy startup costs. On constrained VMs, the default 90-second systemd timeout is not enough.

**Fix**

```bash
# Create a systemd drop-in override to extend the startup timeout
sudo mkdir -p /etc/systemd/system/wazuh-indexer.service.d/

echo -e "[Service]\nTimeoutStartSec=600" \
  | sudo tee /etc/systemd/system/wazuh-indexer.service.d/startup-timeout.conf

sudo systemctl daemon-reload
sudo systemctl start wazuh-indexer
```

---

## 2. Concurrency: The Pro Move

In an event-driven system, multiple alerts can trigger the same action at the same time. Without a "referee," your automation will collide on shared resources.

### The VirtualBox Mutex Lock

**Problem**  
Two alerts fire close together and both try to run `VBoxManage` operations (e.g., snapshot revert) on the same VM. VirtualBox throws `VBOX_E_INVALID_OBJECT_STATE` because the machine is already locked.

**Insight**  
You need a distributed lock so that only one worker can modify a given VM at a time.

**Implementation (Python + Redis)**

```python
import redis
import logging

redis_client = redis.Redis(host="localhost", port=6379, password="YOUR_PASSWORD")
logger = logging.getLogger(__name__)

def run_vbox_command(vm_id: str, action: str) -> None:
    # TODO: Implement the actual VBoxManage call here
    ...

def execute_vbox_action(vm_id: str, action: str) -> None:
    lock_key = f"lock:vm:{vm_id}"

    # nx=True => set only if key does not exist
    # ex=30   => lock automatically expires after 30 seconds
    if redis_client.set(lock_key, "active", nx=True, ex=30):
        try:
            logger.info("Executing %s on VM %s", action, vm_id)
            run_vbox_command(vm_id, action)
        finally:
            # Always release the lock
            redis_client.delete(lock_key)
    else:
        logger.warning("VM %s is currently locked. Skipping %s.", vm_id, action)
```

---

## 3. Resilience: Catching Silent Failures

In queue-based architectures, a service can be "up" but doing nothing while the queue silently grows.

### The Worker Heartbeat

**Problem**  
The Python worker crashes or hangs, but Redis keeps accepting jobs. Analysts click buttons in Slack and see no errors, but nothing happens on the backend.

**Strategy**  
Implement a liveness check outside the worker.

- **Worker:** Every 60 seconds, writes a Unix timestamp to `worker:heartbeat` in Redis with a TTL of 120 seconds.
- **Monitor (e.g., n8n workflow):** Runs on a schedule (e.g., every minute), reads `worker:heartbeat`, compares it with the current time, and raises a **CRITICAL** alert if:
  - The key is missing, or
  - The timestamp is older than a threshold (e.g., 120 seconds).

**Key Principle**  
Always monitor the consumer, not just the queue. A growing queue with no active consumer is the very definition of a "silent failure."

---

## 4. Connectivity: The Tunnel Journey

Getting Slack webhooks into a local lab requires a reliable tunnel. Different options have very different failure modes.

### Tunnel Options and Behavior

| Solution           | Reliability | Typical Failure Mode                                      |
|--------------------|-------------|-----------------------------------------------------------|
| ngrok (Free tier)  | Low         | Truncates large JS bundles, breaking the n8n UI          |
| localtunnel        | Medium      | Frequent disconnects, requires custom retry logic        |
| Cloudflare Tunnel  | High        | Stable, secure, production-grade TLS termination         |

**Final Choice**  
Run `cloudflared` as a sidecar (Docker or host process). It establishes an outbound-only encrypted tunnel from your lab to Cloudflare's edge, so you do not need to expose ports on your router or open your Windows firewall to the internet.

**Benefits**

- Outbound-only connection (safer for home networks)
- Automatic HTTPS/TLS
- Stable URL (with Named Tunnel + domain) suitable for Slack webhook configuration

---

## 5. Performance & Maintenance

### FIM Optimization (Wazuh)

Default File Integrity Monitoring is optimized for compliance, not SOAR. Long scan intervals and broad coverage create blind spots and noise.

**Hybrid Strategy**

- **Real-time monitoring (inotify):**
  - `/etc`
  - `/usr/bin`
  - `/var/www` (or other critical application directories)
- **Frequent polling (e.g., every 300 seconds):**
  - `/home`
- **Ignore noisy/volatile paths:**
  - `/tmp`
  - `/var/log`
  - `/var/cache`

This gives near real-time detection on critical paths while keeping CPU and I/O usage reasonable.

### Maintenance Cheat Sheet

| Task                | Command / Action                                  |
|---------------------|---------------------------------------------------|
| Reset pipeline      | `redis-cli FLUSHALL`                              |
| Check alert backlog | `redis-cli LLEN wazuh:alerts`                     |
| Unlock stuck alert  | `redis-cli DEL lock:alert:<id>`                   |
| Restart Wazuh stack | Restart **Indexer → Manager → Dashboard** in order|

Restart order matters: bring up the indexer first so the manager and dashboard have a healthy backend to talk to.

---

**This runbook is designed to live next to your code as operational documentation.** It not only describes how the system works when everything is healthy, but also how it fails—and how to bring it back.
