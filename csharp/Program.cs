// browser-provisioning / C# — vers-sdk + vers CLI + puppeteer-core (inside VM)
// VERS_API_KEY must be set. `vers` CLI must be on PATH.

using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using VersSdk;

var activeVms = new ConcurrentBag<string>();
VersSdkClient? globalClient = null;

void CleanupVms() {
    if (activeVms.IsEmpty || globalClient == null) return;
    foreach (var vm in activeVms) {
        Console.Error.WriteLine($"[cleanup] Deleting VM {vm}...");
        try { globalClient.DeleteVmAsync(vm).GetAwaiter().GetResult(); } catch {}
    }
}
AppDomain.CurrentDomain.ProcessExit += (_, _) => CleanupVms();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; CleanupVms(); Environment.Exit(1); };

string VersExec(string vmId, string script, int timeout = 600) {
    var psi = new ProcessStartInfo("vers", $"exec -i -t {timeout} {vmId} bash") {
        RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false
    };
    var proc = Process.Start(psi)!;
    proc.StandardInput.Write(script);
    proc.StandardInput.Close();
    var stdout = proc.StandardOutput.ReadToEnd();
    proc.WaitForExit((timeout + 10) * 1000);
    return stdout;
}

void VersWait(string vmId) {
    for (var i = 0; i < 40; i++) {
        try { if (VersExec(vmId, "echo ready", 10).Contains("ready")) return; } catch {}
        Thread.Sleep(3000);
    }
    throw new TimeoutException($"VM {vmId} not ready");
}

const string Install = """
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
    """;

const string Scrape = """
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
    """;

var client = new VersSdkClient();
globalClient = client;

try {
    Console.WriteLine("=== [C#] Building golden image ===\n");

    Console.WriteLine("[1/4] Creating root VM...");
    var root = await client.CreateNewRootVmAsync(
        body: new { vm_config = new { vcpu_count = 2, mem_size_mib = 4096, fs_size_mib = 8192,
            kernel_name = "default.bin", image_name = "default" } });
    var buildVm = root.GetProperty("vm_id").GetString()!;
    activeVms.Add(buildVm);
    Console.WriteLine($"  VM: {buildVm}");

    Console.WriteLine("[2/4] Waiting for VM..."); VersWait(buildVm);
    Console.WriteLine("[3/4] Installing Chromium..."); VersExec(buildVm, Install);

    Console.WriteLine("[4/4] Committing...");
    var cr = await client.CommitVmAsync(buildVm, body: new {});
    var commitId = cr.GetProperty("commit_id").GetString()!;
    Console.WriteLine($"  Commit: {commitId}");
    await client.DeleteVmAsync(buildVm);
    activeVms = new ConcurrentBag<string>(activeVms.Where(v => v != buildVm));
    Console.WriteLine("  Build VM deleted\n");

    Console.WriteLine("=== Branching from commit & scraping ===\n");
    Console.WriteLine("[1/3] Branching...");
    var br = await client.BranchByCommitAsync(commitId, body: new {});
    var vmId = br.GetProperty("vms")[0].GetProperty("vm_id").GetString()!;
    activeVms.Add(vmId);
    Console.WriteLine($"  VM: {vmId}");

    Console.WriteLine("[2/3] Waiting for VM..."); VersWait(vmId);
    Console.WriteLine("[3/3] Starting Chrome & scraping inside VM...\n");
    var output = VersExec(vmId, Scrape, 120);

    foreach (var line in output.Trim().Split('\n')) {
        if (line.StartsWith("{")) {
            using var doc = JsonDocument.Parse(line);
            Console.WriteLine($"Title: {doc.RootElement.GetProperty("title").GetString()}");
            var links = doc.RootElement.GetProperty("links");
            Console.WriteLine($"Links ({links.GetArrayLength()}):");
            foreach (var l in links.EnumerateArray())
                Console.WriteLine($"  {l.GetProperty("text").GetString()} → {l.GetProperty("href").GetString()}");
            break;
        }
    }

    await client.DeleteVmAsync(vmId);
    activeVms = new ConcurrentBag<string>(activeVms.Where(v => v != vmId));
    Console.WriteLine($"\nVM {vmId} deleted. Done.");
} catch (Exception ex) {
    Console.Error.WriteLine($"Fatal: {ex.Message}");
    Environment.Exit(1);
}
