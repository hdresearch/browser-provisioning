# browser-provisioning

Nine programs — one per [Sterling](https://github.com/hdresearch/sterling)-supported
language — that provision a headless Chromium VM on [Vers](https://vers.sh) and scrape
a web page through it.

Each program does:

1. **Create a root VM** via the Vers SDK
2. **SSH in** and install Chromium, Xvfb, Node.js, puppeteer-core
3. **Commit** the VM to create a reusable golden image
4. **Branch from the commit** to get a fresh, fast-spawning VM clone
5. **Start headless Chrome** with `--remote-debugging-port=9222`
6. **Connect via CDP** (or Playwright, Ferrum, chromedp, etc.) and scrape
   `https://example.com` — print the page title and all links
7. **Delete** the branched VM

## Quick start

```bash
export VERS_API_KEY=your-key-here

# Run all 9 languages end-to-end
./run-all.sh

# Or run a single language
./run-all.sh typescript
./run-all.sh python
```

## Languages

| Language   | SDK | Browser lib | Entry point |
|------------|-----|-------------|-------------|
| TypeScript | [vers-sdk](https://github.com/hdresearch/ts-sdk) (npm) | [chrome-remote-interface](https://www.npmjs.com/package/chrome-remote-interface) | `typescript/main.ts` |
| Python     | [vers-sdk](https://github.com/hdresearch/python-sdk) (pip) | [pychrome](https://pypi.org/project/pychrome/) | `python/main.py` |
| Rust       | [vers-sdk](https://github.com/hdresearch/rust-sdk) (cargo) | [chromiumoxide](https://crates.io/crates/chromiumoxide) | `rust/src/main.rs` |
| Go         | [go-sdk](https://github.com/hdresearch/go-sdk) (go get) | [chromedp](https://github.com/chromedp/chromedp) | `go/main.go` |
| Java       | [vers-sdk](https://github.com/hdresearch/java-sdk) (maven) | [java-cdt](https://github.com/nicehash/java-cdt) / raw CDP | `java/…/Main.java` |
| Kotlin     | [vers-sdk](https://github.com/hdresearch/kotlin-sdk) (gradle) | raw CDP via ktor-websockets | `kotlin/…/Main.kt` |
| Ruby       | [vers-sdk](https://github.com/hdresearch/ruby-sdk) (gem) | [ferrum](https://github.com/rubycdp/ferrum) | `ruby/main.rb` |
| PHP        | [vers-sdk](https://github.com/hdresearch/php-sdk) (composer) | [chrome-php/chrome](https://github.com/chrome-php/chrome) | `php/main.php` |
| C#         | [vers-sdk](https://github.com/hdresearch/csharp-sdk) (nuget) | [Playwright](https://playwright.dev/dotnet/) | `csharp/Program.cs` |

## Architecture

```
Your machine                         Vers cloud
────────────                         ──────────
SDK: createNewRootVm() ──────────►  Boot microVM (Ubuntu)
SSH: install chromium, xvfb ──────►  apt-get, npm install
SDK: commitVm() ─────────────────►  Snapshot entire VM state
SDK: branchByCommit() ───────────►  CoW-fork from snapshot (~1-2s)
SSH: start chrome --remote-debug ►  Chrome on :9222 in Xvfb
CDP: connect, navigate, scrape ──►  {vm_id}.vm.vers.sh:9222
SDK: deleteVm() ─────────────────►  Destroy VM
```
