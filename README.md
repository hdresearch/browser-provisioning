# Browser Provisioning Examples

9 programs — one per Sterling-supported language — that demonstrate the Vers VM lifecycle with headless Chrome:

1. **Create** a root VM
2. **Install** Chromium + puppeteer-core via `vers exec`
3. **Commit** the VM (golden image)
4. **Branch** from the commit (instant CoW clone)
5. **Scrape** example.com with headless Chrome + puppeteer inside the VM
6. **Clean up** — delete all VMs even on crash, signal, or error

## Languages

| Language   | SDK                    | Cleanup mechanism                                        |
|------------|------------------------|----------------------------------------------------------|
| TypeScript | vers-sdk (npm)         | `process.on("SIGINT"/"SIGTERM"/"unhandledRejection")`    |
| Python     | vers-sdk (pip)         | `atexit.register()` + `signal.signal()`                  |
| Rust       | vers-sdk (git)         | `Arc<Mutex>` tracker + panic hook + ctrl-c handler       |
| Go         | go-sdk (module)        | `signal.Notify(SIGINT/SIGTERM)` + mutex-protected list   |
| Java       | vers-sdk (mavenLocal)  | `Runtime.addShutdownHook()` + `ConcurrentHashMap`        |
| Kotlin     | vers-sdk (mavenLocal)  | `Runtime.addShutdownHook()` + `ConcurrentHashMap`        |
| Ruby       | vers-sdk (gem)         | `at_exit` + `trap("INT"/"TERM")`                         |
| PHP        | vers-sdk (local path)  | `register_shutdown_function()` + `pcntl_signal()`        |
| C#         | vers-sdk (NuGet)       | `ProcessExit` + `CancelKeyPress`                         |

## Prerequisites

- `VERS_API_KEY` environment variable
- `vers` CLI on PATH
- Language toolchains (auto-detected by `run-all.sh`, missing ones are skipped)

### Toolchain requirements

```
TypeScript: node, npm, npx (tsx)
Python:     python3, pip
Rust:       cargo, rustc
Go:         go
Java:       mvn (+ Java SDK installed to mavenLocal)
Kotlin:     gradle (+ Java SDK in mavenLocal, JDK 21)
Ruby:       ruby, bundle
PHP:        php, composer
C#:         dotnet (10+)
```

### One-time setup for Java/Kotlin

The Java SDK isn't published to Maven Central yet. Install it locally:

```bash
cd ~/hdr/sterling/generated/java
mvn install -DskipTests -Dmaven.test.skip=true
```

## Usage

Run all languages (skips any with missing toolchains):

```bash
VERS_API_KEY=... ./run-all.sh
```

Run specific languages:

```bash
VERS_API_KEY=... ./run-all.sh typescript python go
```

## Architecture

All 9 programs follow the same pattern:

```
SDK: createNewRootVm() → vers exec: install.sh → SDK: commitVm() → SDK: deleteVm()
                                                          ↓
SDK: branchByCommit() → vers exec: scrape.sh → parse JSON → SDK: deleteVm()
```

- **VM lifecycle**: Each language's Vers SDK handles create/commit/branch/delete
- **In-VM commands**: `vers exec -i -t <timeout> <vm_id> bash` pipes scripts into the VM
- **Scraping**: Chrome runs on `localhost:9222` inside the VM; puppeteer-core connects locally
- **No external network exposure** needed — everything runs inside the VM over `vers exec`

## Test Results

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Total time: 1062s
  Passed: 9  Failed: 0  Skipped: 0  (of 9)
    ✓ typescript  (88s)
    ✓ python      (113s)
    ✓ rust        (128s)
    ✓ go          (117s)
    ✓ java        (136s)
    ✓ kotlin      (104s)
    ✓ ruby        (132s)
    ✓ php         (155s)
    ✓ csharp      (89s)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
