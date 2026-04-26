// browser-provisioning / C#
//
// Uses: vers-sdk (nuget), Microsoft.Playwright (CDP), SSH.NET
//
// 1. Create root VM, install Chromium via SSH, commit
// 2. Branch from commit, start Chrome, scrape via CDP
//
// VERS_API_KEY must be set.

using System.Text;
using System.Text.Json;
using Microsoft.Playwright;
using Renci.SshNet;
using VersSdk;

// ── SSH helpers ──────────────────────────────────────────────────────

static string SshExec(string vmId, int port, string privateKey, string command)
{
    using var keyStream = new MemoryStream(Encoding.UTF8.GetBytes(privateKey));
    var key = new PrivateKeyFile(keyStream);
    using var ssh = new SshClient($"{vmId}.vm.vers.sh", port, "root", key);
    ssh.ConnectionInfo.Timeout = TimeSpan.FromSeconds(30);
    ssh.Connect();
    var cmd = ssh.RunCommand(command);
    ssh.Disconnect();
    return cmd.Result;
}

static async Task<(int port, string key)> WaitSsh(VersSdkClient client, string vmId)
{
    var resp = await client.SshKeyAsync(vmId);
    var port = resp.GetProperty("ssh_port").GetInt32();
    var key = resp.GetProperty("ssh_private_key").GetString()!;
    for (var i = 0; i < 40; i++)
    {
        try
        {
            if (SshExec(vmId, port, key, "echo ready").Trim() == "ready")
                return (port, key);
        }
        catch { /* retry */ }
        if (i % 5 == 0) Console.WriteLine($"  Waiting for SSH... ({i}/40)");
        await Task.Delay(3000);
    }
    throw new TimeoutException($"VM {vmId} not ready");
}

// ── Main ─────────────────────────────────────────────────────────────

var client = new VersSdkClient();

// Step 1: Build golden image
Console.WriteLine("=== [C#] Building golden image ===\n");

Console.WriteLine("[1/4] Creating root VM...");
var root = await client.CreateNewRootVmAsync(
    body: new {
        vm_config = new {
            vcpu_count = 2, mem_size_mib = 4096, fs_size_mib = 8192,
            kernel_name = "default.bin", image_name = "default"
        }
    },
    queryParams: new CreateNewRootVmParams { WaitBoot = true }
);
var buildVm = root.GetProperty("vm_id").GetString()!;
Console.WriteLine($"  VM: {buildVm}");

Console.WriteLine("[2/4] Waiting for SSH...");
var (port, key) = await WaitSsh(client, buildVm);

Console.WriteLine("[3/4] Installing Chromium...");
SshExec(buildVm, port, key, """
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
""");

Console.WriteLine("[4/4] Committing...");
var commitResp = await client.CommitVmAsync(buildVm, body: new { });
var commitId = commitResp.GetProperty("commit_id").GetString()!;
Console.WriteLine($"  Commit: {commitId}");
await client.DeleteVmAsync(buildVm);
Console.WriteLine("  Build VM deleted\n");

// Step 2: Branch + scrape
Console.WriteLine("=== Branching from commit & scraping ===\n");

Console.WriteLine("[1/3] Branching...");
var branchResp = await client.BranchByCommitAsync(commitId, body: new { });
var vmId = branchResp.GetProperty("vms")[0].GetProperty("vm_id").GetString()!;
Console.WriteLine($"  VM: {vmId}");

Console.WriteLine("[2/3] Starting Chrome...");
var (port2, key2) = await WaitSsh(client, vmId);
SshExec(vmId, port2, key2, """
    Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
    sleep 1
    export DISPLAY=:99
    CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
    $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
        about:blank &>/dev/null &
    for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
""");

Console.WriteLine("[3/3] Connecting via Playwright CDP...\n");
var cdpUrl = $"http://{vmId}.vm.vers.sh:9222";

using var playwright = await Playwright.CreateAsync();
var browser = await playwright.Chromium.ConnectOverCDPAsync(cdpUrl);
var context = browser.Contexts[0];
var page = context.Pages.Count > 0 ? context.Pages[0] : await context.NewPageAsync();

await page.GotoAsync("https://example.com", new PageGotoOptions { WaitUntil = WaitUntilState.NetworkIdle });

var title = await page.TitleAsync();
Console.WriteLine($"Title: {title}");

var linksJson = await page.EvaluateAsync<string>(
    "() => JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a=>({text:a.textContent.trim(),href:a.href})))"
);
var links = JsonSerializer.Deserialize<List<Dictionary<string, string>>>(linksJson!)!;
Console.WriteLine($"Links ({links.Count}):");
foreach (var l in links)
    Console.WriteLine($"  {l["text"]} → {l["href"]}");

await browser.CloseAsync();

// Cleanup
Console.WriteLine($"\nDeleting VM {vmId}...");
await client.DeleteVmAsync(vmId);
Console.WriteLine("Done.");
