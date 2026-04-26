package com.vers.examples;

import com.google.gson.*;
import com.jcraft.jsch.*;
import com.vers.sdk.Models;
import com.vers.sdk.VersClient;
import org.java_websocket.client.WebSocketClient;
import org.java_websocket.handshake.ServerHandshake;

import java.io.*;
import java.net.*;
import java.net.http.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;

/**
 * browser-provisioning / Java
 *
 * Uses: vers-sdk, JSch (SSH), raw CDP over WebSocket
 *
 * VERS_API_KEY must be set.
 */
public class Main {

    private static final Gson gson = new Gson();

    // ── SSH helpers ─────────────────────────────────────────────────

    static String sshExec(String vmId, int port, String privateKey, String command) throws Exception {
        var keyFile = Files.createTempFile("vers-key-", ".pem");
        Files.writeString(keyFile, privateKey);

        var jsch = new JSch();
        jsch.addIdentity(keyFile.toString());
        var session = jsch.getSession("root", vmId + ".vm.vers.sh", port);
        session.setConfig("StrictHostKeyChecking", "no");
        session.setTimeout(30_000);
        session.connect();

        var ch = (ChannelExec) session.openChannel("exec");
        ch.setCommand(command);
        ch.setInputStream(null);
        var is = ch.getInputStream();
        ch.connect();
        var out = new String(is.readAllBytes());
        ch.disconnect();
        session.disconnect();
        Files.deleteIfExists(keyFile);
        return out;
    }

    record SshInfo(int port, String key) {}

    static SshInfo waitSsh(VersClient client, String vmId) throws Exception {
        var resp = client.sshKey(vmId, null);
        int port = ((Number) resp.get("ssh_port")).intValue();
        String key = (String) resp.get("ssh_private_key");
        for (int i = 0; i < 40; i++) {
            try {
                if (sshExec(vmId, port, key, "echo ready").trim().equals("ready"))
                    return new SshInfo(port, key);
            } catch (Exception ignored) {}
            if (i % 5 == 0) System.out.printf("  Waiting for SSH... (%d/40)%n", i);
            Thread.sleep(3000);
        }
        throw new RuntimeException("VM " + vmId + " not ready");
    }

    // ── CDP helpers ─────────────────────────────────────────────────

    static String cdpSendSync(WebSocketClient ws, int id, String method, JsonObject params,
                               BlockingQueue<JsonObject> responses) throws Exception {
        var msg = new JsonObject();
        msg.addProperty("id", id);
        msg.addProperty("method", method);
        if (params != null) msg.add("params", params);
        ws.send(msg.toString());
        // Wait for matching response
        while (true) {
            var resp = responses.poll(30, TimeUnit.SECONDS);
            if (resp == null) throw new RuntimeException("CDP timeout for " + method);
            if (resp.has("id") && resp.get("id").getAsInt() == id)
                return resp.toString();
        }
    }

    // ── Main ────────────────────────────────────────────────────────

    public static void main(String[] args) throws Exception {
        var client = new VersClient();

        // Step 1: Build golden image
        System.out.println("=== [Java] Building golden image ===\n");

        System.out.println("[1/4] Creating root VM...");
        var createParams = new Models.CreateNewRootVmParams();
        createParams.waitBoot = true;
        var root = client.createNewRootVm(
            Map.of("vm_config", Map.of(
                "vcpu_count", 2, "mem_size_mib", 4096, "fs_size_mib", 8192,
                "kernel_name", "default.bin", "image_name", "default"
            )),
            createParams, null
        );
        String buildVm = (String) root.get("vm_id");
        System.out.printf("  VM: %s%n", buildVm);

        System.out.println("[2/4] Waiting for SSH...");
        var ssh = waitSsh(client, buildVm);

        System.out.println("[3/4] Installing Chromium...");
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
        """);

        System.out.println("[4/4] Committing...");
        var commitResp = client.commitVm(buildVm, Map.of(), null, null);
        String commitId = (String) commitResp.get("commit_id");
        System.out.printf("  Commit: %s%n", commitId);
        client.deleteVm(buildVm, null, null);
        System.out.println("  Build VM deleted\n");

        // Step 2: Branch + scrape
        System.out.println("=== Branching from commit & scraping ===\n");

        System.out.println("[1/3] Branching...");
        var branchResp = client.branchByCommit(commitId, Map.of(), null, null);
        @SuppressWarnings("unchecked")
        var vms = (List<Map<String, Object>>) branchResp.get("vms");
        String vmId = (String) vms.get(0).get("vm_id");
        System.out.printf("  VM: %s%n", vmId);

        System.out.println("[2/3] Starting Chrome...");
        var ssh2 = waitSsh(client, vmId);
        sshExec(vmId, ssh2.port, ssh2.key, """
            Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
            sleep 1
            export DISPLAY=:99
            CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
            $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
                --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
                about:blank &>/dev/null &
            for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
        """);

        System.out.println("[3/3] Connecting via CDP...\n");

        // Get the WS URL from /json/version
        var httpClient = HttpClient.newHttpClient();
        String jsonVersionUrl = String.format("http://%s.vm.vers.sh:9222/json/version", vmId);
        // Retry until Chrome responds
        String wsUrl = null;
        for (int i = 0; i < 20; i++) {
            try {
                var r = httpClient.send(
                    HttpRequest.newBuilder(URI.create(jsonVersionUrl)).build(),
                    HttpResponse.BodyHandlers.ofString()
                );
                var versionObj = JsonParser.parseString(r.body()).getAsJsonObject();
                wsUrl = versionObj.get("webSocketDebuggerUrl").getAsString();
                break;
            } catch (Exception e) { Thread.sleep(1000); }
        }
        if (wsUrl == null) throw new RuntimeException("Chrome not reachable");

        // Connect WebSocket
        var responses = new LinkedBlockingQueue<JsonObject>();
        var ws = new WebSocketClient(URI.create(wsUrl)) {
            public void onOpen(ServerHandshake h) {}
            public void onMessage(String msg) {
                responses.offer(JsonParser.parseString(msg).getAsJsonObject());
            }
            public void onClose(int code, String reason, boolean remote) {}
            public void onError(Exception ex) { ex.printStackTrace(); }
        };
        ws.connectBlocking(10, TimeUnit.SECONDS);

        int msgId = 0;
        cdpSendSync(ws, ++msgId, "Page.enable", null, responses);
        cdpSendSync(ws, ++msgId, "Runtime.enable", null, responses);

        // Navigate
        var navParams = new JsonObject();
        navParams.addProperty("url", "https://example.com");
        cdpSendSync(ws, ++msgId, "Page.navigate", navParams, responses);
        Thread.sleep(3000); // wait for load

        // Get title
        var evalParams = new JsonObject();
        evalParams.addProperty("expression", "document.title");
        var titleResp = JsonParser.parseString(
            cdpSendSync(ws, ++msgId, "Runtime.evaluate", evalParams, responses)
        ).getAsJsonObject();
        String title = titleResp.getAsJsonObject("result")
            .getAsJsonObject("result").get("value").getAsString();
        System.out.printf("Title: %s%n", title);

        // Get links
        var linksEval = new JsonObject();
        linksEval.addProperty("expression",
            "JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a=>({text:a.textContent.trim(),href:a.href})))");
        linksEval.addProperty("returnByValue", true);
        var linksResp = JsonParser.parseString(
            cdpSendSync(ws, ++msgId, "Runtime.evaluate", linksEval, responses)
        ).getAsJsonObject();
        String linksJson = linksResp.getAsJsonObject("result")
            .getAsJsonObject("result").get("value").getAsString();
        var links = JsonParser.parseString(linksJson).getAsJsonArray();
        System.out.printf("Links (%d):%n", links.size());
        for (var l : links) {
            var obj = l.getAsJsonObject();
            System.out.printf("  %s → %s%n", obj.get("text").getAsString(), obj.get("href").getAsString());
        }

        ws.closeBlocking();

        // Cleanup
        System.out.printf("%nDeleting VM %s...%n", vmId);
        client.deleteVm(vmId, null, null);
        System.out.println("Done.");
    }
}
