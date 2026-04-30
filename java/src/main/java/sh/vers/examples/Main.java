package sh.vers.examples;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import sh.vers.sdk.Models;
import sh.vers.sdk.VersClient;

import java.io.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * browser-provisioning / Java — vers-sdk + vers CLI + puppeteer-core (inside VM)
 * VERS_API_KEY must be set. `vers` CLI must be on PATH.
 */
public class Main {

    private static final Set<String> activeVms = ConcurrentHashMap.newKeySet();
    private static VersClient globalClient;

    static {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            for (String vm : activeVms) {
                System.err.printf("[cleanup] Deleting VM %s...%n", vm);
                try { if (globalClient != null) globalClient.deleteVm(vm, null, null); } catch (Exception e) {}
            }
        }));
    }

    static String versExec(String vmId, String script, int timeout) throws Exception {
        var pb = new ProcessBuilder("vers", "exec", "-i", "-t", String.valueOf(timeout), vmId, "bash");
        pb.redirectErrorStream(false);
        var proc = pb.start();
        proc.getOutputStream().write(script.getBytes());
        proc.getOutputStream().close();
        var stdout = new String(proc.getInputStream().readAllBytes());
        proc.waitFor(timeout + 10, TimeUnit.SECONDS);
        return stdout;
    }

    static void versWait(String vmId) throws Exception {
        for (int i = 0; i < 40; i++) {
            try { if (versExec(vmId, "echo ready", 10).contains("ready")) return; } catch (Exception e) {}
            Thread.sleep(3000);
        }
        throw new RuntimeException("VM " + vmId + " not ready");
    }

    static final String INSTALL = """
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq -o Dpkg::Options::="--force-confdef" \\
            libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 \\
            libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 \\
            libgbm1 libasound2t64 libpango-1.0-0 libcairo2 fonts-liberation \\
            xvfb nodejs npm curl ca-certificates
        apt-get remove -y chromium-browser 2>/dev/null || true
        mkdir -p /app && cd /app
        echo '{"dependencies":{"puppeteer-core":"^22.0.0"}}' > package.json
        npm install --quiet 2>&1
        npx puppeteer browsers install chrome 2>&1
    """;

    static final String SCRAPE = """
        Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
        sleep 1
        export DISPLAY=:99
        CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
        $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \\
          --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 \\
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

    @SuppressWarnings("unchecked")
    public static void main(String[] args) throws Exception {
        var client = new VersClient();
        globalClient = client;
        var om = new ObjectMapper();

        try {
            System.out.println("=== [Java] Building golden image ===\n");

            System.out.println("[1/4] Creating root VM...");
            var params = new Models.CreateNewRootVmParams();
            params.wait_boot = true;
            var root = client.createNewRootVm(
                Map.of("vm_config", Map.of("vcpu_count", 2, "mem_size_mib", 4096, "fs_size_mib", 8192,
                    "kernel_name", "default.bin", "image_name", "default")), params, null);
            var buildVm = (String) root.get("vm_id");
            activeVms.add(buildVm);
            System.out.printf("  VM: %s%n", buildVm);

            System.out.println("[2/4] Waiting for VM..."); versWait(buildVm);
            System.out.println("[3/4] Installing Chromium..."); versExec(buildVm, INSTALL, 600);

            System.out.println("[4/4] Committing...");
            var cr = client.commitVm(buildVm, Map.of(), null, null);
            var commitId = (String) cr.get("commit_id");
            System.out.printf("  Commit: %s%n", commitId);
            client.deleteVm(buildVm, null, null); activeVms.remove(buildVm);
            System.out.println("  Build VM deleted\n");

            System.out.println("=== Branching from commit & scraping ===\n");
            System.out.println("[1/3] Branching...");
            var br = client.branchByCommit(commitId, Map.of(), null, null);
            var vms = (List<Map<String,Object>>) br.get("vms");
            var vmId = (String) vms.get(0).get("vm_id");
            activeVms.add(vmId);
            System.out.printf("  VM: %s%n", vmId);

            System.out.println("[2/3] Waiting for VM..."); versWait(vmId);
            System.out.println("[3/3] Starting Chrome & scraping inside VM...\n");
            var out = versExec(vmId, SCRAPE, 120);

            for (var line : out.trim().split("\n")) {
                if (line.startsWith("{")) {
                    JsonNode parsed = om.readTree(line);
                    System.out.printf("Title: %s%n", parsed.get("title").asText());
                    var links = parsed.get("links");
                    System.out.printf("Links (%d):%n", links.size());
                    for (var l : links) {
                        System.out.printf("  %s → %s%n", l.get("text").asText(), l.get("href").asText());
                    }
                    break;
                }
            }

            client.deleteVm(vmId, null, null); activeVms.remove(vmId);
            System.out.printf("%nVM %s deleted. Done.%n", vmId);
        } catch (Exception e) {
            System.err.println("Fatal: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }
}
