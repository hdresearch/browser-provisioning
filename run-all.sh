#!/usr/bin/env bash
#
# run-all.sh — Run browser-provisioning examples for all 9 languages
#              (or specific ones if given as arguments).
#
# Usage:
#   VERS_API_KEY=... ./run-all.sh            # all languages
#   VERS_API_KEY=... ./run-all.sh typescript  # just one
#   VERS_API_KEY=... ./run-all.sh python go   # specific set
#
# Each language uses its Vers SDK for VM lifecycle (create, commit, branch, delete)
# and shells out to `vers exec` to run install/scrape scripts inside VMs.
# Scraping is done inside the VM using puppeteer-core + headless Chrome.
# All programs have cleanup logic: VMs are deleted even on crash/signal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -z "${VERS_API_KEY:-}" ]; then
    echo "Error: VERS_API_KEY must be set"
    exit 1
fi

if ! command -v vers &>/dev/null; then
    echo "Error: vers CLI must be on PATH"
    exit 1
fi

ALL_LANGS=(typescript python rust go java kotlin ruby php csharp)
LANGS=("${@:-${ALL_LANGS[@]}}")

PASS=()
FAIL=()
SKIP=()

log()  { printf "\n\033[1;36m━━━ %s ━━━\033[0m\n\n" "$1"; }
ok()   { printf "\033[1;32m✓ %s passed\033[0m (%ss)\n" "$1" "$2"; PASS+=("$1"); }
fail() { printf "\033[1;31m✗ %s failed\033[0m (%ss)\n" "$1" "$2"; FAIL+=("$1"); }
skip() { printf "\033[1;33m⊘ %s skipped\033[0m (missing: %s)\n" "$1" "$2"; SKIP+=("$1"); }

run_lang() {
    local lang="$1"
    log "$lang"

    case "$lang" in
    typescript)
        command -v npx &>/dev/null || { skip "$lang" "npx/node"; return 0; }
        cd "$SCRIPT_DIR/typescript"
        npm install --silent 2>&1
        npx tsx main.ts
        ;;
    python)
        command -v python3 &>/dev/null || { skip "$lang" "python3"; return 0; }
        cd "$SCRIPT_DIR/python"
        python3 -m venv .venv 2>/dev/null || true
        .venv/bin/pip install -q -r requirements.txt 2>&1
        .venv/bin/python main.py
        ;;
    rust)
        command -v cargo &>/dev/null || { skip "$lang" "cargo/rustc"; return 0; }
        cd "$SCRIPT_DIR/rust"
        cargo run --release 2>&1
        ;;
    go)
        command -v go &>/dev/null || { skip "$lang" "go"; return 0; }
        cd "$SCRIPT_DIR/go"
        go run main.go
        ;;
    java)
        command -v mvn &>/dev/null || { skip "$lang" "mvn"; return 0; }
        cd "$SCRIPT_DIR/java"
        mvn -q compile exec:java -Dexec.mainClass="com.vers.examples.Main" 2>&1
        ;;
    kotlin)
        command -v gradle &>/dev/null || { skip "$lang" "gradle"; return 0; }
        cd "$SCRIPT_DIR/kotlin"
        gradle -q run 2>&1
        ;;
    ruby)
        command -v ruby &>/dev/null && command -v bundle &>/dev/null || { skip "$lang" "ruby/bundle"; return 0; }
        cd "$SCRIPT_DIR/ruby"
        bundle install --quiet 2>&1
        bundle exec ruby main.rb
        ;;
    php)
        command -v php &>/dev/null && command -v composer &>/dev/null || { skip "$lang" "php/composer"; return 0; }
        cd "$SCRIPT_DIR/php"
        composer install --quiet 2>&1
        php main.php
        ;;
    csharp)
        command -v dotnet &>/dev/null || { skip "$lang" "dotnet"; return 0; }
        cd "$SCRIPT_DIR/csharp"
        dotnet run -c Release --nologo
        ;;
    *)
        echo "Unknown language: $lang"
        echo "Available: ${ALL_LANGS[*]}"
        return 1
        ;;
    esac
}

START_TIME=$SECONDS

for lang in "${LANGS[@]}"; do
    LANG_START=$SECONDS
    if run_lang "$lang"; then
        elapsed=$(( SECONDS - LANG_START ))
        # Don't count as "pass" if it was skipped
        if [[ ! " ${SKIP[*]:-} " =~ " $lang " ]]; then
            ok "$lang" "$elapsed"
        fi
    else
        elapsed=$(( SECONDS - LANG_START ))
        fail "$lang" "$elapsed"
    fi
done

TOTAL=$(( SECONDS - START_TIME ))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Total time: ${TOTAL}s"
printf "  Passed: %d  Failed: %d  Skipped: %d  (of %d)\n" "${#PASS[@]}" "${#FAIL[@]}" "${#SKIP[@]}" "${#LANGS[@]}"
[ ${#PASS[@]} -gt 0 ] && printf "    ✓ %s\n" "${PASS[@]}"
[ ${#FAIL[@]} -gt 0 ] && printf "    ✗ %s\n" "${FAIL[@]}"
[ ${#SKIP[@]} -gt 0 ] && printf "    ⊘ %s\n" "${SKIP[@]}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ ${#FAIL[@]} -eq 0 ]
