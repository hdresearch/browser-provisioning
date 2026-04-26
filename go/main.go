// browser-provisioning / Go — go-sdk + vers CLI + puppeteer-core (inside VM)
// VERS_API_KEY must be set. `vers` CLI must be on PATH.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	vers "github.com/hdresearch/go-sdk"
)

type vmTracker struct {
	mu     sync.Mutex
	vms    []string
	client *vers.Client
}

func newTracker(c *vers.Client) *vmTracker {
	t := &vmTracker{client: c}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sigs; fmt.Fprintln(os.Stderr, "\n[cleanup] Signal caught"); t.cleanup(); os.Exit(1) }()
	return t
}
func (t *vmTracker) add(id string)    { t.mu.Lock(); t.vms = append(t.vms, id); t.mu.Unlock() }
func (t *vmTracker) remove(id string) { t.mu.Lock(); for i, v := range t.vms { if v == id { t.vms = append(t.vms[:i], t.vms[i+1:]...); break } }; t.mu.Unlock() }
func (t *vmTracker) cleanup() {
	t.mu.Lock(); vms := append([]string{}, t.vms...); t.mu.Unlock()
	for _, id := range vms {
		fmt.Fprintf(os.Stderr, "[cleanup] Deleting VM %s...\n", id)
		t.client.DeleteVm(id, nil)
	}
}

func versExec(vmID, script string, timeout int) (string, error) {
	cmd := exec.Command("vers", "exec", "-i", "-t", fmt.Sprintf("%d", timeout), vmID, "bash")
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.Output()
	return string(out), err
}

func versWait(vmID string) {
	for i := 0; i < 40; i++ {
		out, err := versExec(vmID, "echo ready", 10)
		if err == nil && strings.Contains(out, "ready") { return }
		time.Sleep(3 * time.Second)
	}
	log.Fatalf("VM %s not ready", vmID)
}

const installScript = `
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
`

const scrapeScript = `
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
`

func run(c *vers.Client, t *vmTracker) error {
	fmt.Println("=== [Go] Building golden image ===\n")

	fmt.Println("[1/4] Creating root VM...")
	waitBoot := true
	resp, err := c.CreateNewRootVm(
		map[string]interface{}{"vm_config": map[string]interface{}{
			"vcpu_count": 2, "mem_size_mib": 4096, "fs_size_mib": 8192,
			"kernel_name": "default.bin", "image_name": "default"}},
		&vers.CreateNewRootVmParams{WaitBoot: &waitBoot})
	if err != nil { return err }
	buildVM := resp.VmId
	t.add(buildVM)
	fmt.Printf("  VM: %s\n", buildVM)

	fmt.Println("[2/4] Waiting for VM..."); versWait(buildVM)
	fmt.Println("[3/4] Installing Chromium...")
	if _, err := versExec(buildVM, installScript, 600); err != nil { return err }

	fmt.Println("[4/4] Committing...")
	commitResp, err := c.CommitVm(buildVM, map[string]interface{}{}, nil)
	if err != nil { return err }
	commitID := commitResp.CommitId
	fmt.Printf("  Commit: %s\n", commitID)
	c.DeleteVm(buildVM, nil); t.remove(buildVM)
	fmt.Println("  Build VM deleted\n")

	fmt.Println("=== Branching from commit & scraping ===\n")
	fmt.Println("[1/3] Branching...")
	branchResp, err := c.BranchByCommit(commitID, map[string]interface{}{}, nil)
	if err != nil { return err }
	vmID := branchResp.Vms[0].VmId
	t.add(vmID)
	fmt.Printf("  VM: %s\n", vmID)

	fmt.Println("[2/3] Waiting for VM..."); versWait(vmID)
	fmt.Println("[3/3] Starting Chrome & scraping inside VM...\n")
	out, err := versExec(vmID, scrapeScript, 120)
	if err != nil { return err }

	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if strings.HasPrefix(line, "{") {
			var data struct {
				Title string `json:"title"`
				Links []struct{ Text, Href string } `json:"links"`
			}
			json.Unmarshal([]byte(line), &data)
			fmt.Printf("Title: %s\n", data.Title)
			fmt.Printf("Links (%d):\n", len(data.Links))
			for _, l := range data.Links { fmt.Printf("  %s → %s\n", l.Text, l.Href) }
			break
		}
	}

	c.DeleteVm(vmID, nil); t.remove(vmID)
	fmt.Printf("\nVM %s deleted. Done.\n", vmID)
	return nil
}

func main() {
	c := vers.NewClient("https://api.vers.sh", "")
	t := newTracker(c)
	if err := run(c, t); err != nil { log.Printf("Fatal: %v", err); t.cleanup(); os.Exit(1) }
}
