package com.vers.examples

import com.google.gson.JsonParser
import com.vers.sdk.VersSdkClient
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * browser-provisioning / Kotlin — vers-sdk + vers CLI + puppeteer-core (inside VM)
 * VERS_API_KEY must be set. `vers` CLI must be on PATH.
 */

private val activeVms: MutableSet<String> = ConcurrentHashMap.newKeySet()
private var globalClient: VersSdkClient? = null

fun versExec(vmId: String, script: String, timeout: Int = 600): String {
    val proc = ProcessBuilder("vers", "exec", "-i", "-t", timeout.toString(), vmId, "bash")
        .redirectErrorStream(false).start()
    proc.outputStream.write(script.toByteArray())
    proc.outputStream.close()
    val stdout = proc.inputStream.readAllBytes().decodeToString()
    proc.waitFor((timeout + 10).toLong(), TimeUnit.SECONDS)
    return stdout
}

fun versWait(vmId: String) {
    repeat(40) {
        try { if ("ready" in versExec(vmId, "echo ready", 10)) return } catch (_: Exception) {}
        Thread.sleep(3000)
    }
    error("VM $vmId not ready")
}

fun cleanupVms() {
    if (activeVms.isEmpty()) return
    activeVms.forEach { vm ->
        System.err.println("[cleanup] Deleting VM $vm...")
        try { runBlocking { globalClient?.deleteVm(vm) } } catch (_: Exception) {}
    }
    activeVms.clear()
}

val INSTALL = """
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
""".trimIndent()

val SCRAPE = """
    Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
    sleep 1
    export DISPLAY=:99
    CHROME=${'$'}(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
    ${'$'}CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
      --remote-debugging-port=9222 --remote-debugging-address=127.0.0.1 \
      about:blank &>/dev/null &
    for i in ${'$'}(seq 1 30); do curl -s http://127.0.0.1:9222/json/version > /dev/null 2>&1 && break; sleep 1; done

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
""".trimIndent()

fun main() = runBlocking {
    val client = VersSdkClient()
    globalClient = client
    Runtime.getRuntime().addShutdownHook(Thread { cleanupVms() })

    try {
        println("=== [Kotlin] Building golden image ===\n")

        println("[1/4] Creating root VM...")
        val root = client.createNewRootVm(
            body = mapOf("vm_config" to mapOf("vcpu_count" to 2, "mem_size_mib" to 4096,
                "fs_size_mib" to 8192, "kernel_name" to "default.bin", "image_name" to "default")),
            params = com.vers.sdk.CreateNewRootVmParams(waitBoot = true))
        val buildVm = root["vm_id"] as String
        activeVms.add(buildVm)
        println("  VM: $buildVm")

        println("[2/4] Waiting for VM..."); versWait(buildVm)
        println("[3/4] Installing Chromium..."); versExec(buildVm, INSTALL)

        println("[4/4] Committing...")
        val cr = client.commitVm(buildVm, body = mapOf())
        val commitId = cr["commit_id"] as String
        println("  Commit: $commitId")
        client.deleteVm(buildVm); activeVms.remove(buildVm)
        println("  Build VM deleted\n")

        println("=== Branching from commit & scraping ===\n")
        println("[1/3] Branching...")
        val br = client.branchByCommit(commitId, body = mapOf())
        @Suppress("UNCHECKED_CAST")
        val vmId = (br["vms"] as List<Map<String, Any?>>)[0]["vm_id"] as String
        activeVms.add(vmId)
        println("  VM: $vmId")

        println("[2/3] Waiting for VM..."); versWait(vmId)
        println("[3/3] Starting Chrome & scraping inside VM...\n")
        val out = versExec(vmId, SCRAPE, 120)

        for (line in out.trim().lines()) {
            if (line.startsWith("{")) {
                val data = JsonParser.parseString(line).asJsonObject
                println("Title: ${data.get("title").asString}")
                val links = data.getAsJsonArray("links")
                println("Links (${links.size()}):")
                for (l in links) {
                    val o = l.asJsonObject
                    println("  ${o.get("text").asString} → ${o.get("href").asString}")
                }
                break
            }
        }

        client.deleteVm(vmId); activeVms.remove(vmId)
        println("\nVM $vmId deleted. Done.")
    } catch (e: Exception) {
        System.err.println("Fatal: ${e.message}")
        System.exit(1)
    }
}
