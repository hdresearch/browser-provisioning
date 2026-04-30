// browser-provisioning / Swift — vers-sdk (SwiftPM) + vers CLI + puppeteer-core (inside VM)
// VERS_API_KEY must be set. `vers` CLI must be on PATH.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import VersSdkSDK

var activeVms: Set<String> = []

func cleanup() {
    let apiKey = ProcessInfo.processInfo.environment["VERS_API_KEY"] ?? ""
    let baseUrl = ProcessInfo.processInfo.environment["VERS_API_BASE_URL"] ?? "https://app.vers.sh"
    for vm in activeVms {
        fputs("[cleanup] Deleting VM \(vm)...\n", stderr)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "-X", "DELETE", "-H", "Authorization: Bearer \(apiKey)", "\(baseUrl)/api/v1/vm/\(vm)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }
}

func versExec(vmId: String, script: String, timeout: Int = 600) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["bash", "-c", "cat <<'EOFSCRIPT' | vers exec -i -t \(timeout) \(vmId) bash\n\(script)\nEOFSCRIPT"]
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

@main
struct BrowserProvisioning {
    static func main() async throws {
        let client = VersSdkClient()

        signal(SIGINT) { _ in cleanup(); _exit(1) }
        signal(SIGTERM) { _ in cleanup(); _exit(1) }

        print("=== [Swift] Building golden image ===\n")
        print("[1/4] Creating root VM...")
        let root = try await client.createNewRootVm(
            body: ["vm_config": ["vcpu_count": 2, "mem_size_mib": 4096, "fs_size_mib": 8192,
                                 "kernel_name": "default.bin", "image_name": "default"] as [String: Any]],
            wait_boot: true)
        let buildVm = root["vm_id"] as! String
        activeVms.insert(buildVm)
        print("  VM: \(buildVm)")

        print("[2/4] Waiting for VM..."); versWait(vmId: buildVm)
        print("[3/4] Installing Chromium...")
        _ = versExec(vmId: buildVm, script: readScript("install.sh"))

        print("[4/4] Committing...")
        let commit = try await client.commitVm(vm_id: buildVm, body: [:])
        let commitId = commit["commit_id"] as! String
        print("  Commit: \(commitId)")
        _ = try await client.deleteVm(vm_id: buildVm)
        activeVms.remove(buildVm)
        print("  Build VM deleted\n")

        print("=== Branching from commit & scraping ===\n")
        print("[1/3] Branching...")
        let branch = try await client.branchByCommit(commit_id: commitId, body: [:])
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

        _ = try await client.deleteVm(vm_id: vmId)
        activeVms.remove(vmId)
        print("\nVM \(vmId) deleted. Done.")
    }
}
