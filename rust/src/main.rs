//! browser-provisioning / Rust — vers-sdk + vers CLI + puppeteer-core (inside VM)
//! VERS_API_KEY must be set. `vers` CLI must be on PATH.

use std::io::Write;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use vers_sdk::{Client, NewRootRequest, VmCreateVmConfig, CreateNewRootVmParams};

fn vers_exec(vm_id: &str, script: &str, timeout: u32) -> String {
    let mut child = Command::new("vers")
        .args(["exec", "-i", "-t", &timeout.to_string(), vm_id, "bash"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn vers exec");
    child.stdin.take().unwrap().write_all(script.as_bytes()).ok();
    let out = child.wait_with_output().expect("wait");
    String::from_utf8_lossy(&out.stdout).to_string()
}

fn vers_wait(vm_id: &str) {
    for _ in 0..40 {
        if vers_exec(vm_id, "echo ready", 10).contains("ready") { return; }
        std::thread::sleep(std::time::Duration::from_secs(3));
    }
    panic!("VM {} not ready", vm_id);
}

#[tokio::main]
async fn main() {
    let client = Client::new("");
    let active: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

    // Ctrl-C cleanup
    let active_c = active.clone();
    ctrlc::set_handler(move || {
        eprintln!("\n[cleanup] Signal caught");
        let key = std::env::var("VERS_API_KEY").unwrap_or_default();
        let base = std::env::var("VERS_BASE_URL").unwrap_or_else(|_| "https://api.vers.sh".into());
        for vm in active_c.lock().unwrap().iter() {
            eprintln!("[cleanup] Deleting VM {}...", vm);
            Command::new("curl").args(["-s","-X","DELETE",&format!("{}/api/v1/vm/{}",base,vm),"-H",&format!("Authorization: Bearer {}",key)]).output().ok();
        }
        std::process::exit(1);
    }).ok();

    let result: Result<(), Box<dyn std::error::Error>> = async {
        println!("=== [Rust] Building golden image ===\n");

        println!("[1/4] Creating root VM...");
        let body = NewRootRequest { vm_config: VmCreateVmConfig {
            vcpu_count: Some(serde_json::Value::from(2)), mem_size_mib: Some(serde_json::Value::from(4096)),
            fs_size_mib: Some(serde_json::Value::from(8192)), kernel_name: Some(serde_json::Value::from("default.bin")),
            image_name: Some(serde_json::Value::from("default")),
        }};
        let root = client.create_new_root_vm(&body, Some(&CreateNewRootVmParams { wait_boot: Some(true) }), None).await?;
        let build_vm = root.vm_id.clone();
        active.lock().unwrap().push(build_vm.clone());
        println!("  VM: {build_vm}");

        println!("[2/4] Waiting for VM..."); vers_wait(&build_vm);
        println!("[3/4] Installing Chromium...");
        vers_exec(&build_vm, include_str!("../install.sh"), 600);

        println!("[4/4] Committing...");
        let cr = client.commit_vm(&build_vm, &serde_json::json!({}), None, None).await?;
        let commit_id = cr["commit_id"].as_str().ok_or("no commit_id")?.to_string();
        println!("  Commit: {commit_id}");
        client.delete_vm(&build_vm, None, None).await?;
        active.lock().unwrap().retain(|v| v != &build_vm);
        println!("  Build VM deleted\n");

        println!("=== Branching from commit & scraping ===\n");
        println!("[1/3] Branching...");
        let br = client.branch_by_commit(&commit_id, &serde_json::json!({}), None, None).await?;
        let vm_id = br.vms[0].vm_id.clone();
        active.lock().unwrap().push(vm_id.clone());
        println!("  VM: {vm_id}");

        println!("[2/3] Waiting for VM..."); vers_wait(&vm_id);
        println!("[3/3] Starting Chrome & scraping inside VM...\n");
        let out = vers_exec(&vm_id, include_str!("../scrape.sh"), 120);

        for line in out.trim().lines() {
            if line.starts_with('{') {
                let data: serde_json::Value = serde_json::from_str(line)?;
                println!("Title: {}", data["title"].as_str().unwrap_or(""));
                if let Some(links) = data["links"].as_array() {
                    println!("Links ({}):", links.len());
                    for l in links { println!("  {} → {}", l["text"].as_str().unwrap_or(""), l["href"].as_str().unwrap_or("")); }
                }
                break;
            }
        }

        client.delete_vm(&vm_id, None, None).await?;
        active.lock().unwrap().retain(|v| v != &vm_id);
        println!("\nVM {vm_id} deleted. Done.");
        Ok(())
    }.await;

    if let Err(e) = result {
        eprintln!("Fatal: {e}");
        // cleanup via ctrl-c handler pattern
        let key = std::env::var("VERS_API_KEY").unwrap_or_default();
        let base = std::env::var("VERS_BASE_URL").unwrap_or_else(|_| "https://api.vers.sh".into());
        for vm in active.lock().unwrap().iter() {
            let _ = reqwest::Client::new().delete(format!("{}/api/v1/vm/{}", base, vm))
                .header("Authorization", format!("Bearer {}", key)).send().await;
        }
        std::process::exit(1);
    }
}
