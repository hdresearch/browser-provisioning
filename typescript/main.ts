#!/usr/bin/env npx tsx
// browser-provisioning / TypeScript
//
// Uses: vers-sdk (npm), chrome-remote-interface (CDP)
//
// 1. Create root VM, install Chromium via SSH, commit
// 2. Branch from commit, start Chrome, scrape via CDP
//
// VERS_API_KEY must be set.

import { VersSdkClient, connectVmSSH } from "vers-sdk";
import CDP from "chrome-remote-interface";

const client = new VersSdkClient();

// ── helpers ─────────────────────────────────────────────────────────

async function waitReady(vmId: string, maxSec = 120): Promise<void> {
  const deadline = Date.now() + maxSec * 1000;
  while (Date.now() < deadline) {
    try {
      const ssh = await connectVmSSH(client, vmId, `${vmId}.vm.vers.sh`);
      const r = await ssh.execute("echo ready");
      if (r.stdout.trim() === "ready") return;
    } catch {}
    await new Promise((r) => setTimeout(r, 3000));
  }
  throw new Error(`VM ${vmId} not ready after ${maxSec}s`);
}

async function sshRun(vmId: string, cmd: string): Promise<string> {
  const ssh = await connectVmSSH(client, vmId, `${vmId}.vm.vers.sh`);
  const r = await ssh.execute(cmd);
  if (r.exitCode !== 0) console.error(`  [exit=${r.exitCode}] ${r.stderr.slice(0, 300)}`);
  return r.stdout;
}

// ── Step 1: Build golden image ──────────────────────────────────────

console.log("=== [TypeScript] Building golden image ===\n");

console.log("[1/4] Creating root VM...");
const root = await client.createNewRootVm(
  { vm_config: { vcpu_count: 2, mem_size_mib: 4096, fs_size_mib: 8192, kernel_name: "default.bin", image_name: "default" } },
  { wait_boot: true },
);
const buildVm = root.vm_id;
console.log(`  VM: ${buildVm}`);

console.log("[2/4] Waiting for SSH...");
await waitReady(buildVm);

console.log("[3/4] Installing Chromium...");
await sshRun(buildVm, `
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
`);

console.log("[4/4] Committing...");
const { commit_id: commitId } = await client.commitVm(buildVm, {});
console.log(`  Commit: ${commitId}`);
await client.deleteVm(buildVm);
console.log(`  Build VM deleted\n`);

// ── Step 2: Branch + scrape ─────────────────────────────────────────

console.log("=== Branching from commit & scraping ===\n");

console.log("[1/3] Branching...");
const branch = await client.branchByCommit(commitId, {});
const vmId = branch.vms[0].vm_id;
console.log(`  VM: ${vmId}`);

console.log("[2/3] Starting Chrome...");
await waitReady(vmId);
await sshRun(vmId, `
  Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
  sleep 1
  export DISPLAY=:99
  CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
  $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
    about:blank &>/dev/null &
  for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
`);

console.log("[3/3] Connecting via CDP...\n");
const cdp = await CDP({ host: `${vmId}.vm.vers.sh`, port: 9222 });
const { Page, Runtime } = cdp;
await Page.enable();
await Runtime.enable();

await Page.navigate({ url: "https://example.com" });
await Page.loadEventFired();

const title = await Runtime.evaluate({ expression: "document.title" });
console.log(`Title: ${title.result.value}`);

const linksResult = await Runtime.evaluate({
  expression: `JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a => ({ text: a.textContent.trim(), href: a.href })))`,
  returnByValue: true,
});
const links = JSON.parse(linksResult.result.value as string);
console.log(`Links (${links.length}):`);
for (const l of links) console.log(`  ${l.text} → ${l.href}`);

await cdp.close();

// ── Cleanup ─────────────────────────────────────────────────────────

console.log(`\nDeleting VM ${vmId}...`);
await client.deleteVm(vmId);
console.log("Done.");
