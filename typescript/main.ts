#!/usr/bin/env npx tsx
// browser-provisioning / TypeScript
//
// Uses: vers-sdk (npm) + vers CLI (for exec) + puppeteer-core (inside VM)
//
// VERS_API_KEY must be set. `vers` CLI must be on PATH.

import { execFileSync } from "child_process";
import { VersSdkClient } from "vers-sdk";

const client = new VersSdkClient();
const activeVms = new Set<string>();

async function cleanup() {
  for (const vm of activeVms) {
    try { console.error(`[cleanup] Deleting VM ${vm}...`); await client.deleteVm(vm); console.error(`[cleanup] Deleted ${vm}`); } catch {}
  }
  activeVms.clear();
}
process.on("unhandledRejection", async (e) => { console.error("Unhandled:", e); await cleanup(); process.exit(1); });
for (const s of ["SIGINT", "SIGTERM"] as const) process.on(s, async () => { await cleanup(); process.exit(1); });

/** Run a script inside a Vers VM via `vers exec -i -t <timeout> <vm> bash`. */
function versExec(vmId: string, script: string, timeoutSec = 600): string {
  return execFileSync("vers", ["exec", "-i", "-t", String(timeoutSec), vmId, "bash"], {
    input: script,
    encoding: "utf-8",
    timeout: (timeoutSec + 10) * 1000, // local timeout slightly larger than remote
    maxBuffer: 50 * 1024 * 1024,
  });
}

function versExecWait(vmId: string, maxSec = 120) {
  const deadline = Date.now() + maxSec * 1000;
  while (Date.now() < deadline) {
    try { const r = versExec(vmId, "echo ready", 10); if (r.trim().includes("ready")) return; } catch {}
    execFileSync("sleep", ["3"]);
  }
  throw new Error(`VM ${vmId} not ready after ${maxSec}s`);
}

try {
  console.log("=== [TypeScript] Building golden image ===\n");

  console.log("[1/4] Creating root VM...");
  const root = await client.createNewRootVm(
    { vm_config: { vcpu_count: 2, mem_size_mib: 4096, fs_size_mib: 8192, kernel_name: "default.bin", image_name: "default" } },
    { wait_boot: true },
  );
  const buildVm = root.vm_id;
  activeVms.add(buildVm);
  console.log(`  VM: ${buildVm}`);

  console.log("[2/4] Waiting for VM...");
  versExecWait(buildVm);

  console.log("[3/4] Installing Chromium...");
  versExec(buildVm, `
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
  `);

  console.log("[4/4] Committing...");
  const { commit_id: commitId } = await client.commitVm(buildVm, {});
  console.log(`  Commit: ${commitId}`);
  await client.deleteVm(buildVm);
  activeVms.delete(buildVm);
  console.log(`  Build VM deleted\n`);

  // ── Branch + scrape ─────────────────────────────────────────────
  console.log("=== Branching from commit & scraping ===\n");

  console.log("[1/3] Branching...");
  const branch = await client.branchByCommit(commitId, {});
  const vmId = branch.vms[0].vm_id;
  activeVms.add(vmId);
  console.log(`  VM: ${vmId}`);

  console.log("[2/3] Waiting for VM...");
  versExecWait(vmId);

  console.log("[3/3] Starting Chrome & scraping inside VM...\n");
  const output = versExec(vmId, String.raw`
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
  `);

  const jsonLine = output.trim().split("\n").find(l => l.startsWith("{"));
  if (jsonLine) {
    const data = JSON.parse(jsonLine);
    console.log(`Title: ${data.title}`);
    console.log(`Links (${data.links.length}):`);
    for (const l of data.links) console.log(`  ${l.text} → ${l.href}`);
  } else {
    console.log("Raw output:", output.trim());
  }

  await client.deleteVm(vmId);
  activeVms.delete(vmId);
  console.log(`\nVM ${vmId} deleted. Done.`);

} catch (err) {
  console.error("Fatal error:", err);
  await cleanup();
  process.exit(1);
}
