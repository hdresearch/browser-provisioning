#!/usr/bin/env python3
"""
browser-provisioning / Python

Uses: vers-sdk (pip), pychrome (CDP), paramiko (SSH)

1. Create root VM, install Chromium via SSH, commit
2. Branch from commit, start Chrome, scrape via CDP

VERS_API_KEY must be set.
"""

import asyncio
import io
import json
import sys
import time

import paramiko
import pychrome

from vers_sdk import VersSdkClient


# ── SSH helpers ──────────────────────────────────────────────────────

def _ssh_connect(host: str, port: int, private_key: str) -> paramiko.SSHClient:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    pkey = paramiko.Ed25519Key.from_private_key(io.StringIO(private_key))
    ssh.connect(hostname=host, port=port, username="root", pkey=pkey, timeout=30)
    return ssh


def ssh_exec(ssh: paramiko.SSHClient, command: str, timeout: int = 600) -> str:
    _, stdout, stderr = ssh.exec_command(command, timeout=timeout)
    exit_code = stdout.channel.recv_exit_status()
    out = stdout.read().decode()
    if exit_code != 0:
        err = stderr.read().decode()
        print(f"  [exit={exit_code}] {err[:300]}", file=sys.stderr)
    return out


async def get_ssh(client: VersSdkClient, vm_id: str):
    resp = await client.ssh_key(vm_id)
    return resp.ssh_port, resp.ssh_private_key


async def wait_ssh(client: VersSdkClient, vm_id: str, max_sec: int = 120) -> paramiko.SSHClient:
    port, key = await get_ssh(client, vm_id)
    deadline = time.time() + max_sec
    while time.time() < deadline:
        try:
            ssh = _ssh_connect(f"{vm_id}.vm.vers.sh", port, key)
            ssh_exec(ssh, "echo ready")
            return ssh
        except Exception:
            pass
        await asyncio.sleep(3)
    raise TimeoutError(f"VM {vm_id} not ready after {max_sec}s")


# ── main ─────────────────────────────────────────────────────────────

async def main():
    client = VersSdkClient()

    # Step 1: Build golden image
    print("=== [Python] Building golden image ===\n")

    print("[1/4] Creating root VM...")
    root = await client.create_new_root_vm(
        body={
            "vm_config": {
                "vcpu_count": 2, "mem_size_mib": 4096, "fs_size_mib": 8192,
                "kernel_name": "default.bin", "image_name": "default",
            }
        },
        params={"wait_boot": True},
    )
    build_vm = root.vm_id
    print(f"  VM: {build_vm}")

    print("[2/4] Waiting for SSH...")
    ssh = await wait_ssh(client, build_vm)

    print("[3/4] Installing Chromium...")
    ssh_exec(ssh, """
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
    """)
    ssh.close()

    print("[4/4] Committing...")
    commit_resp = await client.commit_vm(build_vm, body={})
    commit_id = commit_resp.commit_id
    print(f"  Commit: {commit_id}")
    await client.delete_vm(build_vm)
    print(f"  Build VM deleted\n")

    # Step 2: Branch + scrape
    print("=== Branching from commit & scraping ===\n")

    print("[1/3] Branching...")
    branch = await client.branch_by_commit(commit_id, body={})
    vm_id = branch.vms[0].vm_id
    print(f"  VM: {vm_id}")

    print("[2/3] Starting Chrome...")
    ssh = await wait_ssh(client, vm_id)
    ssh_exec(ssh, """
        Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
        sleep 1
        export DISPLAY=:99
        CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
        $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
            --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
            about:blank &>/dev/null &
        for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
    """)
    ssh.close()

    print("[3/3] Connecting via CDP...\n")
    browser = pychrome.Browser(url=f"http://{vm_id}.vm.vers.sh:9222")
    tab = browser.new_tab()
    tab.start()
    tab.Page.enable()
    tab.Runtime.enable()

    tab.Page.navigate(url="https://example.com")
    tab.wait(5)

    title = tab.Runtime.evaluate(expression="document.title")
    print(f"Title: {title['result']['value']}")

    links_raw = tab.Runtime.evaluate(
        expression="JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a => ({text: a.textContent.trim(), href: a.href})))"
    )
    links = json.loads(links_raw["result"]["value"])
    print(f"Links ({len(links)}):")
    for link in links:
        print(f"  {link['text']} → {link['href']}")

    tab.stop()
    browser.close_tab(tab)

    # Cleanup
    print(f"\nDeleting VM {vm_id}...")
    await client.delete_vm(vm_id)
    print("Done.")


if __name__ == "__main__":
    asyncio.run(main())
