#!/usr/bin/env bash
#
# run-all.sh — Run browser-provisioning examples for all 9 languages
#              (or a single language if given as argument).
#
# Usage:
#   VERS_API_KEY=... ./run-all.sh            # all languages
#   VERS_API_KEY=... ./run-all.sh typescript  # just one
#   VERS_API_KEY=... ./run-all.sh python go   # specific set
#
# Each language:
#   1. Creates a root VM, installs Chromium via SSH, commits (golden image)
#   2. Branches from the commit, starts headless Chrome, scrapes example.com via CDP
#   3. Prints the page title and links, then cleans up

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -z "${VERS_API_KEY:-}" ]; then
    echo "Error: VERS_API_KEY must be set"
    exit 1
fi

ALL_LANGS=(typescript python rust go java kotlin ruby php csharp)
LANGS=("${@:-${ALL_LANGS[@]}}")

PASS=()
FAIL=()

# ── Utilities ────────────────────────────────────────────────────────

log()  { printf "\n\033[1;36m━━━ %s ━━━\033[0m\n\n" "$1"; }
ok()   { printf "\033[1;32m✓ %s passed\033[0m\n" "$1"; PASS+=("$1"); }
fail() { printf "\033[1;31m✗ %s failed\033[0m\n" "$1"; FAIL+=("$1"); }

run_lang() {
    local lang="$1"
    log "$lang"

    case "$lang" in

    typescript)
        cd "$SCRIPT_DIR/typescript"
        npm install --silent 2>&1
        npx tsx main.ts
        ;;

    python)
        cd "$SCRIPT_DIR/python"
        python3 -m venv .venv 2>/dev/null || true
        .venv/bin/pip install -q -r requirements.txt 2>&1
        .venv/bin/python main.py
        ;;

    rust)
        cd "$SCRIPT_DIR/rust"
        cargo run --release 2>&1
        ;;

    go)
        cd "$SCRIPT_DIR/go"
        go run main.go
        ;;

    java)
        cd "$SCRIPT_DIR/java"
        mvn -q compile exec:java -Dexec.mainClass="com.vers.examples.Main" 2>&1
        ;;

    kotlin)
        cd "$SCRIPT_DIR/kotlin"
        gradle -q run 2>&1
        ;;

    ruby)
        cd "$SCRIPT_DIR/ruby"
        bundle install --quiet 2>&1
        bundle exec ruby main.rb
        ;;

    php)
        cd "$SCRIPT_DIR/php"
        composer install --quiet 2>&1
        php main.php
        ;;

    csharp)
        cd "$SCRIPT_DIR/csharp"
        # Install Playwright browsers on first run
        dotnet build -c Release --nologo -v q 2>&1
        pwsh -Command "& { \$env:PLAYWRIGHT_BROWSERS_PATH='0'; npx playwright install chromium }" 2>/dev/null || true
        dotnet run -c Release --no-build
        ;;

    *)
        echo "Unknown language: $lang"
        echo "Available: ${ALL_LANGS[*]}"
        return 1
        ;;
    esac
}

# ── Main loop ────────────────────────────────────────────────────────

START_TIME=$SECONDS

for lang in "${LANGS[@]}"; do
    LANG_START=$SECONDS
    if run_lang "$lang"; then
        ok "$lang ($(( SECONDS - LANG_START ))s)"
    else
        fail "$lang ($(( SECONDS - LANG_START ))s)"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────

TOTAL=$(( SECONDS - START_TIME ))

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Total time: ${TOTAL}s"
echo "  Passed: ${#PASS[@]}/${#LANGS[@]}"
if [ ${#PASS[@]} -gt 0 ]; then
    printf "    ✓ %s\n" "${PASS[@]}"
fi
if [ ${#FAIL[@]} -gt 0 ]; then
    printf "    ✗ %s\n" "${FAIL[@]}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ ${#FAIL[@]} -eq 0 ]
