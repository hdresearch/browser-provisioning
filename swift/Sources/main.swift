// browser-provisioning / Swift — vers-sdk (SwiftPM) + vers CLI + puppeteer-core (inside VM)
// VERS_API_KEY must be set. `vers` CLI must be on PATH.

import Foundation
import VersSdkSDK

var activeVms: Set<String> = []
let client = VersSdkClient()

func cleanup() {
    for vm in activeVms {
        fputs("[cleanup] Deleting VM \(vm)...\n", stderr)
        _ = try? runAsync { try await client.deleteVm(vm_id: vm) }
    }
}

func runAsync<T>(_ block: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task {
        do { result = .success(try await block()) }
        catch { result = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try result.get()
}

signal(SIGINT) { _ in cleanup(); exit(1) }
signal(SIGTERM) { _ in cleanup(); exit(1) }

func versExec(vmId: String, script: String, timeout: Int = 600) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = ["-c", "cat <<'EOFSCRIPT' | vers exec -i -t \(timeout) \(vmId) bash\n\(script)\nEOFSCRIPT"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func versWait(vmId: String) {
    for _ in 0..<40 {
        if versExec(vmId: vmId, script: "echo ready", timeout: 10).contains("ready") { return }
        Thread.sleep(forTimeInterval: 3)
    }
    fatalError("VM \(vmId) not ready")
}

func readScript(_ name: String) -> String {
    try! String(contentsOfFile: "../\(name)", encoding: .utf8)
}

do {
    print("=== [Swift] Building golden image ===\n")
    print("[1/4] Creating root VM...")
    let root = try runAsync {
        try await client.createNewRootVm(
            body: ["vm_config": ["vcpu_count": 2, "mem_size_mib": 4096, "fs_size_mib": 8192,
                                 "kernel_name": "default.bin", "image_name": "default"] as [String: Any]],
            wait_boot: true)
    }
    let buildVm = root["vm_id"] as! String
    activeVms.insert(buildVm)
    print("  VM: \(buildVm)")

    print("[2/4] Waiting for VM..."); versWait(vmId: buildVm)
    print("[3/4] Installing Chromium...")
    _ = versExec(vmId: buildVm, script: readScript("install.sh"))

    print("[4/4] Committing...")
    let commit = try runAsync { try await client.commitVm(vm_id: buildVm, body: [:]) }
    let commitId = commit["commit_id"] as! String
    print("  Commit: \(commitId)")
    _ = try runAsync { try await client.deleteVm(vm_id: buildVm) }
    activeVms.remove(buildVm)
    print("  Build VM deleted\n")

    print("=== Branching from commit & scraping ===\n")
    print("[1/3] Branching...")
    let branch = try runAsync { try await client.branchByCommit(commit_id: commitId, body: [:]) }
    let vmId = (branch["vms"] as! [[String: Any]])[0]["vm_id"] as! String
    activeVms.insert(vmId)
    print("  VM: \(vmId)")

    print("[2/3] Waiting for VM..."); versWait(vmId: vmId)
    print("[3/3] Scraping...\n")
    let output = versExec(vmId: vmId, script: readScript("scrape.sh"), timeout: 120)
    for line in output.split(separator: "\n") where line.hasPrefix("{") {
        let d = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        print("Title: \(d["title"] as! String)")
        let links = d["links"] as! [[String: Any]]
        print("Links (\(links.count)):")
        for l in links { print("  \(l["text"]!) → \(l["href"]!)") }
        break
    }

    _ = try runAsync { try await client.deleteVm(vm_id: vmId) }
    activeVms.remove(vmId)
    print("\nVM \(vmId) deleted. Done.")
} catch {
    fputs("Fatal: \(error)\n", stderr); cleanup(); exit(1)
}
