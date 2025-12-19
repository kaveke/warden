#!/usr/bin/env python3
"""
🛡️ Wazuh SOAR Worker V3: Host Control (Configurable)
----------------------------------------------------
Role: The "Muscle" of the pipeline.
Input: Consumes tasks from Redis List 'wazuh:actions'.
Logic: Uses 'vm_config.json' to map Agents to VMs.
"""

import redis
import json
import subprocess
import os
import logging
import time
from abc import ABC, abstractmethod
from datetime import datetime
from dotenv import load_dotenv

# Load env variables
load_dotenv()

# ==========================================
# ⚙️ GLOBAL CONFIGURATION
# ==========================================
REDIS_HOST = os.getenv('REDIS_HOST', '127.0.0.1')
REDIS_PORT = int(os.getenv('REDIS_PORT', 6379))
REDIS_PASS = os.getenv('REDIS_PASSWORD', None)
QUEUE_NAME = 'wazuh:actions'
LOG_CHANNEL = 'wazuh:logs'
CONFIG_FILE = 'vm_config.json'

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] 🐍 %(message)s',
    handlers=[logging.StreamHandler()]
)
logger = logging.getLogger("SOAR-Worker")

# ==========================================
# 📂 CONFIGURATION LOADER
# ==========================================
class ConfigManager:
    @staticmethod
    def load_mapping():
        """Loads the Agent->VM mapping from JSON file"""
        try:
            if not os.path.exists(CONFIG_FILE):
                logger.warning(f"⚠️ {CONFIG_FILE} not found. Using identity mapping (AgentName = VMName).")
                return {}
            
            with open(CONFIG_FILE, 'r') as f:
                data = json.load(f)
                logger.info(f"✅ Loaded {len(data.get('vm_mapping', {}))} VM mappings from config.")
                return data.get('vm_mapping', {})
        except Exception as e:
            logger.error(f"❌ Failed to load config: {e}")
            return {}

# ==========================================
# 🏗️ ISOLATION STRATEGIES
# ==========================================
class IsolationStrategy(ABC):
    @abstractmethod
    def isolate_host(self, target_id: str) -> dict:
        pass

class VirtualBoxStrategy(IsolationStrategy):
    def __init__(self, vm_mapping):
        self.mapping = vm_mapping

    def _get_vm_name(self, target):
        """Resolves Wazuh Agent ID/Name to VBox VM Name"""
        # 1. Try direct lookup (e.g., "001" -> "Win11")
        if target in self.mapping:
            return self.mapping[target]
        
        # 2. Fallback: Assume the target IS the VM name
        logger.warning(f"⚠️ No mapping found for '{target}'. Trying to use it as VM Name directly.")
        return target

    def _run(self, cmd):
        try:
            # shell=True required for Windows paths often, strict timeout prevents hanging
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
            return result.returncode == 0, result.stdout.strip(), result.stderr.strip()
        except Exception as e:
            return False, "", str(e)

    def isolate_host(self, target_identifier: str) -> dict:
        vm_name = self._get_vm_name(target_identifier)
        logger.info(f"🔒 INITIATING ISOLATION for Target: '{target_identifier}' (Mapped to VM: '{vm_name}')")
        
        report = []
        
        # 1. PAUSE
        ok, _, err = self._run(f'VBoxManage controlvm "{vm_name}" pause')
        if not ok: return {"status": "error", "step": "pause", "details": err}
        report.append("✅ VM Paused")

        # 2. SNAPSHOT
        snap_name = f"isolation_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        ok, _, err = self._run(f'VBoxManage snapshot "{vm_name}" take "{snap_name}"')
        if ok: report.append(f"✅ Snapshot created: {snap_name}")
        else: logger.warning(f"Snapshot failed (Non-fatal): {err}")

        # 3. NIC DISCONNECT
        ok, _, err = self._run(f'VBoxManage controlvm "{vm_name}" nic1 none')
        if not ok: return {"status": "error", "step": "network_cut", "details": err}
        report.append("✅ Network Disconnected")

        # 4. RESUME
        self._run(f'VBoxManage controlvm "{vm_name}" resume')
        report.append("✅ VM Resumed (Isolated)")

        return {"status": "success", "report": report}

# ==========================================
# 🤖 WORKER MAIN LOOP
# ==========================================
class SoarWorker:
    def __init__(self):
        # Load Config once on startup
        self.vm_mapping = ConfigManager.load_mapping()
        self.strategy = VirtualBoxStrategy(self.vm_mapping)
        
        # Redis Connection
        self.redis = redis.Redis(
            host=REDIS_HOST, port=REDIS_PORT, password=REDIS_PASS, decode_responses=True
        )

    def listen(self):
        logger.info(f"👂 Worker Online. Listening on {QUEUE_NAME}...")
        while True:
            try:
                _, raw_data = self.redis.blpop(QUEUE_NAME)
                logger.info(f"📨 Task Received: {raw_data}")
                self.process_task(json.loads(raw_data))
            except redis.ConnectionError as e:
                logger.error(f"❌ Redis Connection Lost: {e}. Retrying in 5s...")
                time.sleep(5)
            except Exception as e:
                logger.error(f"🔥 Critical Error: {e}")

    def process_task(self, task):
        # Parsing Logic (Slack vs Direct JSON)
        action = "unknown"
        target = "unknown"

        if "value" in task: # From Slack
            parts = task["value"].split("|")
            if len(parts) >= 2: action, target = parts[0], parts[1]
        elif "task" in task: # From Test Script
            action = task.get("task")
            target = task.get("target")

        # Execution
        result = {}
        if action == "isolate":
            result = self.strategy.isolate_host(target)
        else:
            logger.warning(f"⚠️ Unknown Action: {action}")
            return

        # Log Result
        log_entry = json.dumps({"timestamp": datetime.now().isoformat(), "target": target, "result": result})
        self.redis.lpush(LOG_CHANNEL, log_entry)
        logger.info(f"🏁 Task Finished: {result.get('status', 'unknown')}")

if __name__ == "__main__":
    worker = SoarWorker()
    worker.listen()
