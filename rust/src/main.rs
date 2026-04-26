//! browser-provisioning / Rust
//!
//! Uses: vers-sdk (cargo), chromiumoxide (CDP)
//!
//! 1. Create root VM, install Chromium via SSH, commit
//! 2. Branch from commit, start Chrome, scrape via CDP
//!
//! VERS_API_KEY must be set.

use std::time::Duration;
use chromiumoxide::browser::Browser;
use futures::StreamExt;
use vers_sdk::{Client, NewRootRequest, VmCreateVmConfig, CreateNewRootVmParams};

// Shell out to ssh — keeps the example dependency-light.
async fn ssh_exec(vm_id: &str, port: u16, key: &str, cmd: &str) -> String {
    let key_path = format!("/tmp/vers-key-{}", vm_id);
    std::fs::write(&key_path, key).expect("write key");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&key_path, std::fs::Permissions::from_mode(0o600)).ok();
    }
    let out = tokio::process::Command::new("ssh")
        .args([
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=30",
            "-i", &key_path,
            "-p", &port.to_string(),
            &format!("root@{}.vm.vers.sh", vm_id),
            cmd,
        ])
        .output()
        .await
        .expect("ssh");
    std::fs::remove_file(&key_path).ok();
    String::from_utf8_lossy(&out.stdout).to_string()
}

async fn wait_ssh(client: &Client, vm_id: &str) -> (u16, String) {
    let info = client.ssh_key(vm_id, None).await.expect("ssh_key");
    let port = info.ssh_port;
    let key = info.ssh_private_key.clone();
    for i in 0..40 {
        let r = ssh_exec(vm_id, port, &key, "echo ready").await;
        if r.trim() == "ready" { return (port, key); }
        if i % 5 == 0 { eprintln!("  Waiting for SSH... ({i}/40)"); }
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    panic!("VM {} not ready", vm_id);
}

#[tokio::main]
async fn main() {
    let client = Client::new("");

    // ── Build golden image ──────────────────────────────────────────
    println!("=== [Rust] Building golden image ===\n");

    println!("[1/4] Creating root VM...");
    let body = NewRootRequest {
        vm_config: VmCreateVmConfig {
            vcpu_count: Some(serde_json::Value::from(2)),
            mem_size_mib: Some(serde_json::Value::from(4096)),
            fs_size_mib: Some(serde_json::Value::from(8192)),
            kernel_name: Some(serde_json::Value::from("default.bin")),
            image_name: Some(serde_json::Value::from("default")),
        },
    };
    let params = CreateNewRootVmParams { wait_boot: Some(true) };
    let root = client.create_new_root_vm(&body, Some(&params), None).await.expect("create");
    let build_vm = &root.vm_id;
    println!("  VM: {build_vm}");

    println!("[2/4] Waiting for SSH...");
    let (port, key) = wait_ssh(&client, build_vm).await;

    println!("[3/4] Installing Chromium...");
    ssh_exec(build_vm, port, &key, r#"
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
    "#).await;

    println!("[4/4] Committing...");
    let empty: serde_json::Value = serde_json::json!({});
    let commit_resp = client.commit_vm(build_vm, &empty, None, None).await.expect("commit");
    let commit_id = commit_resp["commit_id"].as_str().expect("commit_id").to_string();
    println!("  Commit: {commit_id}");
    client.delete_vm(build_vm, None, None).await.expect("delete build");
    println!("  Build VM deleted\n");

    // ── Branch + scrape ─────────────────────────────────────────────
    println!("=== Branching from commit & scraping ===\n");

    println!("[1/3] Branching...");
    let branch = client.branch_by_commit(&commit_id, &empty, None, None).await.expect("branch");
    let vm_id = &branch.vms[0].vm_id;
    println!("  VM: {vm_id}");

    println!("[2/3] Starting Chrome...");
    let (port2, key2) = wait_ssh(&client, vm_id).await;
    ssh_exec(vm_id, port2, &key2, r#"
        Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
        sleep 1
        export DISPLAY=:99
        CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
        $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
            --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
            about:blank &>/dev/null &
        for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
    "#).await;

    println!("[3/3] Connecting via CDP...\n");
    let ws_url = format!("http://{}.vm.vers.sh:9222", vm_id);
    let (mut browser, mut handler) = Browser::connect(&ws_url).await.expect("cdp connect");
    let _handle = tokio::spawn(async move { while handler.next().await.is_some() {} });

    let page = browser.new_page("about:blank").await.expect("page");
    page.goto("https://example.com").await.expect("navigate");
    tokio::time::sleep(Duration::from_secs(3)).await;

    let title: String = page.evaluate("document.title").await.expect("title").into_value().expect("val");
    println!("Title: {title}");

    let links: Vec<serde_json::Value> = page.evaluate(
        r#"Array.from(document.querySelectorAll('a[href]')).map(a=>({text:a.textContent.trim(),href:a.href}))"#
    ).await.expect("links").into_value().expect("val");
    println!("Links ({}):", links.len());
    for l in &links {
        println!("  {} → {}", l["text"].as_str().unwrap_or(""), l["href"].as_str().unwrap_or(""));
    }

    drop(page);
    browser.close().await.expect("close");

    // Cleanup
    println!("\nDeleting VM {vm_id}...");
    client.delete_vm(vm_id, None, None).await.expect("delete");
    println!("Done.");
}
