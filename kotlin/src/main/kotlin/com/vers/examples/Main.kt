package com.vers.examples

import com.google.gson.JsonParser
import com.jcraft.jsch.ChannelExec
import com.jcraft.jsch.JSch
import com.vers.sdk.VersSdkClient
import io.ktor.client.*
import io.ktor.client.engine.cio.*
import io.ktor.client.plugins.websocket.*
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.websocket.*
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.nio.file.Files

/**
 * browser-provisioning / Kotlin
 *
 * Uses: vers-sdk, JSch (SSH), ktor-websockets for raw CDP
 *
 * VERS_API_KEY must be set.
 */

fun sshExec(vmId: String, port: Int, privateKey: String, command: String): String {
    val keyFile = Files.createTempFile("vers-key-", ".pem")
    Files.writeString(keyFile, privateKey)
    val jsch = JSch()
    jsch.addIdentity(keyFile.toString())
    val session = jsch.getSession("root", "$vmId.vm.vers.sh", port)
    session.setConfig("StrictHostKeyChecking", "no")
    session.timeout = 30_000
    session.connect()
    val ch = session.openChannel("exec") as ChannelExec
    ch.setCommand(command)
    ch.inputStream = null
    val stdout = ch.inputStream
    ch.connect()
    val out = stdout.readAllBytes().decodeToString()
    ch.disconnect()
    session.disconnect()
    Files.deleteIfExists(keyFile)
    return out
}

data class SshInfo(val port: Int, val key: String)

suspend fun waitSsh(client: VersSdkClient, vmId: String): SshInfo {
    val resp = client.sshKey(vmId)
    val port = (resp["ssh_port"] as Number).toInt()
    val key = resp["ssh_private_key"] as String
    repeat(40) { i ->
        try {
            if (sshExec(vmId, port, key, "echo ready").trim() == "ready")
                return SshInfo(port, key)
        } catch (_: Exception) {}
        if (i % 5 == 0) println("  Waiting for SSH... ($i/40)")
        delay(3000)
    }
    error("VM $vmId not ready")
}

fun main() = runBlocking {
    val client = VersSdkClient()

    // ── Build golden image ──────────────────────────────────────────
    println("=== [Kotlin] Building golden image ===\n")

    println("[1/4] Creating root VM...")
    val root = client.createNewRootVm(
        body = mapOf("vm_config" to mapOf(
            "vcpu_count" to 2, "mem_size_mib" to 4096, "fs_size_mib" to 8192,
            "kernel_name" to "default.bin", "image_name" to "default"
        )),
        params = com.vers.sdk.CreateNewRootVmParams(waitBoot = true)
    )
    val buildVm = root["vm_id"] as String
    println("  VM: $buildVm")

    println("[2/4] Waiting for SSH...")
    val ssh = waitSsh(client, buildVm)

    println("[3/4] Installing Chromium...")
    sshExec(buildVm, ssh.port, ssh.key, """
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
    """.trimIndent())

    println("[4/4] Committing...")
    val commitResp = client.commitVm(buildVm, body = mapOf())
    val commitId = commitResp["commit_id"] as String
    println("  Commit: $commitId")
    client.deleteVm(buildVm)
    println("  Build VM deleted\n")

    // ── Branch + scrape ─────────────────────────────────────────────
    println("=== Branching from commit & scraping ===\n")

    println("[1/3] Branching...")
    val branchResp = client.branchByCommit(commitId, body = mapOf())
    @Suppress("UNCHECKED_CAST")
    val vms = branchResp["vms"] as List<Map<String, Any?>>
    val vmId = vms[0]["vm_id"] as String
    println("  VM: $vmId")

    println("[2/3] Starting Chrome...")
    val ssh2 = waitSsh(client, vmId)
    sshExec(vmId, ssh2.port, ssh2.key, """
        Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
        sleep 1
        export DISPLAY=:99
        CHROME=${'$'}(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
        ${'$'}CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
            --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
            about:blank &>/dev/null &
        for i in ${'$'}(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
    """.trimIndent())

    println("[3/3] Connecting via CDP...\n")

    // Get WS URL
    val httpClient = HttpClient(CIO) { install(WebSockets) }
    var wsUrl: String? = null
    repeat(20) {
        try {
            val body = httpClient.get("http://$vmId.vm.vers.sh:9222/json/version").bodyAsText()
            wsUrl = JsonParser.parseString(body).asJsonObject.get("webSocketDebuggerUrl").asString
            return@repeat
        } catch (_: Exception) { delay(1000) }
    }
    requireNotNull(wsUrl) { "Chrome not reachable" }

    // CDP via ktor-websockets
    val wsUri = java.net.URI(wsUrl!!)
    var msgId = 0
    httpClient.webSocket(host = wsUri.host, port = wsUri.port, path = wsUri.path) {
        suspend fun cdpSend(method: String, params: String = "{}"): String {
            val id = ++msgId
            send("""{"id":$id,"method":"$method","params":$params}""")
            while (true) {
                val frame = incoming.receive() as? Frame.Text ?: continue
                val text = frame.readText()
                val obj = JsonParser.parseString(text).asJsonObject
                if (obj.has("id") && obj.get("id").asInt == id) return text
            }
        }

        cdpSend("Page.enable")
        cdpSend("Runtime.enable")
        cdpSend("Page.navigate", """{"url":"https://example.com"}""")
        delay(3000)

        val titleResp = JsonParser.parseString(
            cdpSend("Runtime.evaluate", """{"expression":"document.title"}""")
        ).asJsonObject
        val title = titleResp.getAsJsonObject("result").getAsJsonObject("result").get("value").asString
        println("Title: $title")

        val linksResp = JsonParser.parseString(
            cdpSend("Runtime.evaluate", """{"expression":"JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a=>({text:a.textContent.trim(),href:a.href})))","returnByValue":true}""")
        ).asJsonObject
        val linksJson = linksResp.getAsJsonObject("result").getAsJsonObject("result").get("value").asString
        val links = JsonParser.parseString(linksJson).asJsonArray
        println("Links (${links.size()}):")
        for (l in links) {
            val o = l.asJsonObject
            println("  ${o.get("text").asString} → ${o.get("href").asString}")
        }
    }

    httpClient.close()

    // Cleanup
    println("\nDeleting VM $vmId...")
    client.deleteVm(vmId)
    println("Done.")
}
