# Browser Provisioning Examples

13 programs — one per Sterling-supported language — that demonstrate the Vers VM lifecycle with headless Chrome:

1. **Create** a root VM
2. **Install** Chromium + puppeteer-core via `vers exec`
3. **Commit** the VM (golden image)
4. **Branch** from the commit (instant CoW clone)
5. **Scrape** example.com with headless Chrome + puppeteer inside the VM
6. **Clean up** — delete all VMs even on crash, signal, or error

## Languages

| Language   | SDK                          | Registry / Install                                       |
|------------|------------------------------|----------------------------------------------------------|
| TypeScript | `vers-sdk`                   | [npm](https://www.npmjs.com/package/vers-sdk) `^0.1.8`  |
| Python     | `vers-sdk`                   | [PyPI](https://pypi.org/project/vers-sdk/) `>=0.1.8`    |
| Rust       | `vers-sdk`                   | [crates.io](https://crates.io/crates/vers-sdk) `0.1.8`  |
| Go         | `github.com/hdresearch/go-sdk` | [Go proxy](https://pkg.go.dev/github.com/hdresearch/go-sdk) `v0.1.8` |
| Java       | `sh.vers:vers-sdk`           | Maven Central `0.1.8`                                    |
| Kotlin     | `sh.vers:vers-sdk`           | Maven Central `0.1.8`                                    |
| Ruby       | `vers-sdk`                   | [RubyGems](https://rubygems.org/gems/vers-sdk) `~> 0.1.8` |
| PHP        | `vers/sdk`                   | [Packagist](https://packagist.org/packages/vers/sdk) `dev-main` |
| C#         | `vers-sdk`                   | [NuGet](https://www.nuget.org/packages/vers-sdk) `0.1.8` |
| Dart       | `vers_sdk`                   | Git (`hdresearch/dart-sdk`)                              |
| Scala      | `sh.vers:vers-sdk`           | Maven Central `0.1.8`                                    |
| Swift      | `swift-sdk`                  | SwiftPM (`hdresearch/swift-sdk`)                         |
| Zig        | `vers_sdk`                   | Zig package (`hdresearch/zig-sdk`)                       |

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
Java:       mvn, java (JDK 21+)
Kotlin:     gradle, java (JDK 21+)
Ruby:       ruby, bundle
PHP:        php, composer
C#:         dotnet (8+)
Dart:       dart
Scala:      sbt, java (JDK 21+)
Swift:      swift (5.9+)
Zig:        zig (0.15+)
```

## Usage

Run all languages (skips any with missing toolchains):

```bash
VERS_API_KEY=... ./run-all.sh
```

Run specific languages:

```bash
VERS_API_KEY=... ./run-all.sh typescript python go dart
```

## Architecture

All 13 programs follow the same pattern:

```
SDK: createNewRootVm() → vers exec: install.sh → SDK: commitVm() → SDK: deleteVm()
                                                          ↓
SDK: branchByCommit() → vers exec: scrape.sh → parse JSON → SDK: deleteVm()
```

- **VM lifecycle**: Each language's Vers SDK handles create/commit/branch/delete
- **In-VM commands**: `vers exec -i -t <timeout> <vm_id> bash` pipes scripts into the VM
- **Scraping**: Chrome runs on `localhost:9222` inside the VM; puppeteer-core connects locally
- **No external network exposure** needed — everything runs inside the VM over `vers exec`
