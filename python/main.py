#!/usr/bin/env python3
"""browser-provisioning / Python — vers-sdk + vers CLI + puppeteer-core (inside VM)"""

import asyncio, atexit, os, signal, subprocess, sys
from vers_sdk import VersSdkClient
from vers_sdk.models import CreateNewRootVmParams

_active_vms: set[str] = set()
_client: VersSdkClient | None = None

def _sync_cleanup():
    if not _active_vms or not _client:
        return
    import httpx
    hdr = {"Authorization": f"Bearer {_client.api_key}"} if _client.api_key else {}
    for vm in list(_active_vms):
        try:
            print(f"[cleanup] Deleting VM {vm}...", file=sys.stderr)
            httpx.delete(f"{_client.base_url}/api/v1/vm/{vm}", headers=hdr, timeout=30)
            print(f"[cleanup] Deleted {vm}", file=sys.stderr)
        except Exception as e:
            print(f"[cleanup] Failed: {e}", file=sys.stderr)
    _active_vms.clear()

atexit.register(_sync_cleanup)
signal.signal(signal.SIGINT, lambda *_: (_sync_cleanup(), sys.exit(1)))
signal.signal(signal.SIGTERM, lambda *_: (_sync_cleanup(), sys.exit(1)))

def vers_exec(vm_id: str, script: str, timeout: int = 600) -> str:
    r = subprocess.run(
        ["vers", "exec", "-i", "-t", str(timeout), vm_id, "bash"],
        input=script, capture_output=True, text=True, timeout=timeout + 10,
    )
    if r.returncode != 0:
        print(f"  [vers exec exit={r.returncode}] {r.stderr[:500]}", file=sys.stderr)
    return r.stdout

def vers_wait(vm_id: str, max_sec: int = 120):
    import time
    deadline = time.time() + max_sec
    while time.time() < deadline:
        try:
            if "ready" in vers_exec(vm_id, "echo ready", timeout=10):
                return
        except Exception:
            pass
        time.sleep(3)
    raise TimeoutError(f"VM {vm_id} not ready after {max_sec}s")

INSTALL_SCRIPT = r"""
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq -o Dpkg::Options::="--force-confdef" \
    libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
    libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \
    libgbm1 libasound2t64 libpango-1.0-0 libcairo2 fonts-liberation \
    xvfb nodejs npm curl ca-certificates
apt-get remove -y chromium-browser 2>/dev/null || true
mkdir -p /app && cd /app
echo '{"dependencies":{"puppeteer-core":"^22.0.0"}}' > package.json
npm install --quiet 2>&1
npx puppeteer browsers install chrome 2>&1
"""

SCRAPE_SCRIPT = r"""
Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
sleep 1
export DISPLAY=:99
CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
$CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 \
  about:blank &>/dev/null &
for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version > /dev/null 2>&1 && break; sleep 1; done

cd /app && node -e '
  const puppeteer = require("puppeteer-core");
  (async () => {
    const browser = await puppeteer.connect({ browserURL: "http://127.0.0.1:9222" });
    const page = await browser.newPage();
    await page.goto("https://example.com", { waitUntil: "networkidle2", timeout: 30000 });
    const title = await page.title();
    const links = await page.evaluate(() =>
      Array.from(document.querySelectorAll("a[href]")).map(a => ({text: a.textContent.trim(), href: a.href}))
    );
    console.log(JSON.stringify({title, links}));
    await browser.disconnect();
  })();
'
"""

async def main():
    global _client
    client = VersSdkClient()
    _client = client

    try:
        print("=== [Python] Building golden image ===\n")

        print("[1/4] Creating root VM...")
        root = await client.create_new_root_vm(
            body={"vm_config": {"vcpu_count": 2, "mem_size_mib": 4096, "fs_size_mib": 8192,
                                "kernel_name": "default.bin", "image_name": "default"}},
            params=CreateNewRootVmParams(wait_boot=True),
        )
        build_vm = root["vm_id"]
        _active_vms.add(build_vm)
        print(f"  VM: {build_vm}")

        print("[2/4] Waiting for VM...")
        vers_wait(build_vm)

        print("[3/4] Installing Chromium...")
        vers_exec(build_vm, INSTALL_SCRIPT)

        print("[4/4] Committing...")
        commit = await client.commit_vm(build_vm, body={})
        commit_id = commit["commit_id"]
        print(f"  Commit: {commit_id}")
        await client.delete_vm(build_vm)
        _active_vms.discard(build_vm)
        print("  Build VM deleted\n")

        print("=== Branching from commit & scraping ===\n")

        print("[1/3] Branching...")
        branch = await client.branch_by_commit(commit_id, body={})
        vm_id = branch["vms"][0]["vm_id"]
        _active_vms.add(vm_id)
        print(f"  VM: {vm_id}")

        print("[2/3] Waiting for VM...")
        vers_wait(vm_id)

        print("[3/3] Starting Chrome & scraping inside VM...\n")
        output = vers_exec(vm_id, SCRAPE_SCRIPT, timeout=120)

        import json
        for line in output.strip().split("\n"):
            if line.startswith("{"):
                data = json.loads(line)
                print(f"Title: {data['title']}")
                print(f"Links ({len(data['links'])}):")
                for l in data["links"]:
                    print(f"  {l['text']} → {l['href']}")
                break

        await client.delete_vm(vm_id)
        _active_vms.discard(vm_id)
        print(f"\nVM {vm_id} deleted. Done.")

    except Exception:
        import traceback; traceback.print_exc()
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main())
