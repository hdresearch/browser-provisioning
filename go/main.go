// browser-provisioning / Go
//
// Uses: go-sdk, chromedp (CDP)
//
// 1. Create root VM, install Chromium via SSH, commit
// 2. Branch from commit, start Chrome, scrape via CDP
//
// VERS_API_KEY must be set.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/chromedp/chromedp"
	vers "github.com/hdresearch/go-sdk"
)

func sshExec(vmID string, port int32, key, command string) (string, error) {
	kf := fmt.Sprintf("/tmp/vers-key-%s", vmID)
	os.WriteFile(kf, []byte(key), 0600)
	defer os.Remove(kf)
	out, err := exec.Command("ssh",
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
		"-o", "ConnectTimeout=30",
		"-i", kf,
		"-p", fmt.Sprintf("%d", port),
		fmt.Sprintf("root@%s.vm.vers.sh", vmID),
		command,
	).CombinedOutput()
	return string(out), err
}

func waitSSH(c *vers.Client, vmID string) (int32, string, error) {
	resp, err := c.SshKey(vmID)
	if err != nil {
		return 0, "", err
	}
	port := resp.SshPort
	key := resp.SshPrivateKey
	for i := 0; i < 40; i++ {
		out, err := sshExec(vmID, port, key, "echo ready")
		if err == nil && strings.TrimSpace(out) == "ready" {
			return port, key, nil
		}
		if i%5 == 0 {
			fmt.Printf("  Waiting for SSH... (%d/40)\n", i)
		}
		time.Sleep(3 * time.Second)
	}
	return 0, "", fmt.Errorf("VM %s not ready", vmID)
}

func main() {
	c := vers.NewClient("", "")

	// ── Build golden image ──────────────────────────────────────────
	fmt.Println("=== [Go] Building golden image ===\n")

	fmt.Println("[1/4] Creating root VM...")
	waitBoot := true
	root, err := c.CreateNewRootVm(
		map[string]interface{}{
			"vm_config": map[string]interface{}{
				"vcpu_count": 2, "mem_size_mib": 4096, "fs_size_mib": 8192,
				"kernel_name": "default.bin", "image_name": "default",
			},
		},
		&vers.CreateNewRootVmParams{WaitBoot: &waitBoot},
	)
	if err != nil {
		log.Fatal(err)
	}
	buildVM := root.VmId
	fmt.Printf("  VM: %s\n", buildVM)

	fmt.Println("[2/4] Waiting for SSH...")
	port, key, err := waitSSH(c, buildVM)
	if err != nil {
		log.Fatal(err)
	}

	fmt.Println("[3/4] Installing Chromium...")
	sshExec(buildVM, port, key, `
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
	`)

	fmt.Println("[4/4] Committing...")
	commitResp, err := c.CommitVm(buildVM, map[string]interface{}{}, nil)
	if err != nil {
		log.Fatal(err)
	}
	commitID := commitResp.CommitId
	fmt.Printf("  Commit: %s\n", commitID)
	c.DeleteVm(buildVM, nil)
	fmt.Println("  Build VM deleted\n")

	// ── Branch + scrape ─────────────────────────────────────────────
	fmt.Println("=== Branching from commit & scraping ===\n")

	fmt.Println("[1/3] Branching...")
	branch, err := c.BranchByCommit(commitID, map[string]interface{}{}, nil)
	if err != nil {
		log.Fatal(err)
	}
	vmID := branch.Vms[0].VmId
	fmt.Printf("  VM: %s\n", vmID)

	fmt.Println("[2/3] Starting Chrome...")
	port2, key2, err := waitSSH(c, vmID)
	if err != nil {
		log.Fatal(err)
	}
	sshExec(vmID, port2, key2, `
		Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
		sleep 1
		export DISPLAY=:99
		CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
		$CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
			--remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
			about:blank &>/dev/null &
		for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
	`)

	fmt.Println("[3/3] Connecting via CDP...\n")
	wsURL := fmt.Sprintf("ws://%s.vm.vers.sh:9222", vmID)
	actx, acancel := chromedp.NewRemoteAllocator(context.Background(), wsURL)
	defer acancel()
	ctx, cancel := chromedp.NewContext(actx)
	defer cancel()
	ctx, cancel = context.WithTimeout(ctx, 60*time.Second)
	defer cancel()

	var title, linksJSON string
	err = chromedp.Run(ctx,
		chromedp.Navigate("https://example.com"),
		chromedp.WaitReady("body"),
		chromedp.Title(&title),
		chromedp.Evaluate(`JSON.stringify(Array.from(document.querySelectorAll('a[href]')).map(a=>({text:a.textContent.trim(),href:a.href})))`, &linksJSON),
	)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("Title: %s\n", title)

	var links []struct {
		Text string `json:"text"`
		Href string `json:"href"`
	}
	json.Unmarshal([]byte(linksJSON), &links)
	fmt.Printf("Links (%d):\n", len(links))
	for _, l := range links {
		fmt.Printf("  %s → %s\n", l.Text, l.Href)
	}

	// Cleanup
	fmt.Printf("\nDeleting VM %s...\n", vmID)
	c.DeleteVm(vmID, nil)
	fmt.Println("Done.")
}
