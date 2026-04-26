<?php
/**
 * browser-provisioning / PHP — vers-sdk + vers CLI + puppeteer-core (inside VM)
 * VERS_API_KEY must be set. `vers` CLI must be on PATH.
 */

require_once __DIR__ . '/vendor/autoload.php';

use VersSdk\VersSdkClient;

$activeVms = [];
$client = null;

function cleanupVms(): void {
    global $activeVms, $client;
    foreach ($activeVms as $vm) {
        fwrite(STDERR, "[cleanup] Deleting VM $vm...\n");
        try { $client?->deleteVm($vm); } catch (\Throwable $e) {}
    }
    $activeVms = [];
}

register_shutdown_function('cleanupVms');
if (function_exists('pcntl_signal')) {
    pcntl_signal(SIGINT, function() { cleanupVms(); exit(1); });
    pcntl_signal(SIGTERM, function() { cleanupVms(); exit(1); });
}

function versExec(string $vmId, string $script, int $timeout = 600): string {
    $proc = proc_open(
        ['vers', 'exec', '-i', '-t', (string)$timeout, $vmId, 'bash'],
        [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes
    );
    fwrite($pipes[0], $script);
    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($proc);
    return $stdout;
}

function versWait(string $vmId): void {
    for ($i = 0; $i < 40; $i++) {
        try {
            if (str_contains(versExec($vmId, "echo ready", 10), "ready")) return;
        } catch (\Throwable $e) {}
        sleep(3);
    }
    throw new \RuntimeException("VM $vmId not ready");
}

$INSTALL = <<<'BASH'
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
BASH;

$SCRAPE = <<<'BASH'
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
BASH;

try {
    $client = new VersSdkClient(apiKey: getenv('VERS_API_KEY') ?: null);

    echo "=== [PHP] Building golden image ===\n\n";

    echo "[1/4] Creating root VM...\n";
    $root = $client->createNewRootVm(
        body: ['vm_config' => ['vcpu_count' => 2, 'mem_size_mib' => 4096, 'fs_size_mib' => 8192,
            'kernel_name' => 'default.bin', 'image_name' => 'default']]
    );
    $buildVm = $root['vm_id'];
    $activeVms[] = $buildVm;
    echo "  VM: $buildVm\n";

    echo "[2/4] Waiting for VM...\n"; versWait($buildVm);
    echo "[3/4] Installing Chromium...\n"; versExec($buildVm, $INSTALL);

    echo "[4/4] Committing...\n";
    $cr = $client->commitVm($buildVm, body: []);
    $commitId = $cr['commit_id'];
    echo "  Commit: $commitId\n";
    $client->deleteVm($buildVm);
    $activeVms = array_diff($activeVms, [$buildVm]);
    echo "  Build VM deleted\n\n";

    echo "=== Branching from commit & scraping ===\n\n";
    echo "[1/3] Branching...\n";
    $br = $client->branchByCommit($commitId, body: []);
    $vmId = $br['vms'][0]['vm_id'];
    $activeVms[] = $vmId;
    echo "  VM: $vmId\n";

    echo "[2/3] Waiting for VM...\n"; versWait($vmId);
    echo "[3/3] Starting Chrome & scraping inside VM...\n\n";
    $out = versExec($vmId, $SCRAPE, 120);

    foreach (explode("\n", trim($out)) as $line) {
        if (str_starts_with($line, '{')) {
            $data = json_decode($line, true);
            echo "Title: {$data['title']}\n";
            $links = $data['links'];
            echo "Links (" . count($links) . "):\n";
            foreach ($links as $l) {
                echo "  {$l['text']} → {$l['href']}\n";
            }
            break;
        }
    }

    $client->deleteVm($vmId);
    $activeVms = array_diff($activeVms, [$vmId]);
    echo "\nVM $vmId deleted. Done.\n";

} catch (\Throwable $e) {
    fwrite(STDERR, "Fatal: " . $e->getMessage() . "\n");
    exit(1);
}
