#!/usr/bin/env php
<?php
/**
 * browser-provisioning / PHP
 *
 * Uses: vers-sdk (composer), chrome-php/chrome (CDP), phpseclib (SSH)
 *
 * 1. Create root VM, install Chromium via SSH, commit
 * 2. Branch from commit, start Chrome, scrape via CDP
 *
 * VERS_API_KEY must be set.
 */

require_once __DIR__ . '/vendor/autoload.php';

use VersSdk\VersSdkClient;
use VersSdk\CreateNewRootVmParams;
use HeadlessChromium\BrowserFactory;
use phpseclib3\Net\SSH2;
use phpseclib3\Crypt\PublicKeyLoader;

// ── SSH helpers ──────────────────────────────────────────────────────

function sshExec(string $vmId, int $port, string $privateKey, string $command): string
{
    $ssh = new SSH2("$vmId.vm.vers.sh", $port);
    $key = PublicKeyLoader::load($privateKey);
    if (!$ssh->login('root', $key)) {
        throw new RuntimeException("SSH login failed for VM $vmId");
    }
    $output = $ssh->exec($command);
    $ssh->disconnect();
    return $output ?: '';
}

function waitSsh(VersSdkClient $client, string $vmId): array
{
    $resp = $client->sshKey($vmId);
    $port = $resp['ssh_port'];
    $key = $resp['ssh_private_key'];
    for ($i = 0; $i < 40; $i++) {
        try {
            if (trim(sshExec($vmId, $port, $key, 'echo ready')) === 'ready') {
                return ['port' => $port, 'key' => $key];
            }
        } catch (\Throwable $e) {}
        if ($i % 5 === 0) echo "  Waiting for SSH... ($i/40)\n";
        sleep(3);
    }
    throw new RuntimeException("VM $vmId not ready");
}

// ── Main ─────────────────────────────────────────────────────────────

$client = new VersSdkClient();

// Step 1: Build golden image
echo "=== [PHP] Building golden image ===\n\n";

echo "[1/4] Creating root VM...\n";
$root = $client->createNewRootVm(
    body: [
        'vm_config' => [
            'vcpu_count' => 2, 'mem_size_mib' => 4096, 'fs_size_mib' => 8192,
            'kernel_name' => 'default.bin', 'image_name' => 'default',
        ],
    ],
    params: new CreateNewRootVmParams(waitBoot: true),
);
$buildVm = $root['vm_id'];
echo "  VM: $buildVm\n";

echo "[2/4] Waiting for SSH...\n";
$ssh = waitSsh($client, $buildVm);

echo "[3/4] Installing Chromium...\n";
sshExec($buildVm, $ssh['port'], $ssh['key'], <<<'BASH'
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
BASH);

echo "[4/4] Committing...\n";
$commitResp = $client->commitVm($buildVm, body: []);
$commitId = $commitResp['commit_id'];
echo "  Commit: $commitId\n";
$client->deleteVm($buildVm);
echo "  Build VM deleted\n\n";

// Step 2: Branch + scrape
echo "=== Branching from commit & scraping ===\n\n";

echo "[1/3] Branching...\n";
$branchResp = $client->branchByCommit($commitId, body: []);
$vmId = $branchResp['vms'][0]['vm_id'];
echo "  VM: $vmId\n";

echo "[2/3] Starting Chrome...\n";
$ssh2 = waitSsh($client, $vmId);
sshExec($vmId, $ssh2['port'], $ssh2['key'], <<<'BASH'
    Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
    sleep 1
    export DISPLAY=:99
    CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
    $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
        about:blank &>/dev/null &
    for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
BASH);

echo "[3/3] Connecting via chrome-php CDP...\n\n";
$browserFactory = new BrowserFactory();
$browser = $browserFactory->connectTo("http://$vmId.vm.vers.sh:9222");
$page = $browser->createPage();

$page->navigate('https://example.com')->waitForNavigation();

$title = $page->evaluate('document.title')->getReturnValue();
echo "Title: $title\n";

$linksJson = $page->evaluate(
    "JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a=>({text:a.textContent.trim(),href:a.href})))"
)->getReturnValue();
$links = json_decode($linksJson, true);
echo "Links (" . count($links) . "):\n";
foreach ($links as $l) {
    echo "  {$l['text']} → {$l['href']}\n";
}

$browser->close();

// Cleanup
echo "\nDeleting VM $vmId...\n";
$client->deleteVm($vmId);
echo "Done.\n";
