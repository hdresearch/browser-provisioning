#!/usr/bin/env ruby
# frozen_string_literal: true

# browser-provisioning / Ruby
#
# Uses: vers-sdk (gem), ferrum (CDP), net-ssh
#
# 1. Create root VM, install Chromium via SSH, commit
# 2. Branch from commit, start Chrome, scrape via CDP
#
# VERS_API_KEY must be set.

require "vers_sdk"
require "ferrum"
require "net/ssh"
require "json"
require "tempfile"

# ── SSH helpers ──────────────────────────────────────────────────────

def ssh_exec(vm_id, port, private_key, command)
  key_file = Tempfile.new(["vers-key", ".pem"])
  key_file.write(private_key)
  key_file.close
  File.chmod(0o600, key_file.path)

  output = ""
  Net::SSH.start(
    "#{vm_id}.vm.vers.sh", "root",
    port: port, keys: [key_file.path],
    verify_host_key: :never, timeout: 30
  ) { |ssh| output = ssh.exec!(command) || "" }

  key_file.unlink
  output
end

def wait_ssh(client, vm_id)
  resp = client.ssh_key(vm_id)
  port = resp["ssh_port"]
  key = resp["ssh_private_key"]

  40.times do |i|
    begin
      return [port, key] if ssh_exec(vm_id, port, key, "echo ready").strip == "ready"
    rescue StandardError
    end
    puts "  Waiting for SSH... (#{i}/40)" if (i % 5).zero?
    sleep 3
  end
  raise "VM #{vm_id} not ready"
end

# ── Main ─────────────────────────────────────────────────────────────

client = VersSdk::VersSdkClient.new

# Step 1: Build golden image
puts "=== [Ruby] Building golden image ===\n\n"

puts "[1/4] Creating root VM..."
root = client.create_new_root_vm(
  body: {
    "vm_config" => {
      "vcpu_count" => 2, "mem_size_mib" => 4096, "fs_size_mib" => 8192,
      "kernel_name" => "default.bin", "image_name" => "default"
    }
  },
  params: { "wait_boot" => true }
)
build_vm = root["vm_id"]
puts "  VM: #{build_vm}"

puts "[2/4] Waiting for SSH..."
port, key = wait_ssh(client, build_vm)

puts "[3/4] Installing Chromium..."
ssh_exec(build_vm, port, key, <<~BASH)
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
BASH

puts "[4/4] Committing..."
commit_resp = client.commit_vm(build_vm, body: {})
commit_id = commit_resp["commit_id"]
puts "  Commit: #{commit_id}"
client.delete_vm(build_vm)
puts "  Build VM deleted\n\n"

# Step 2: Branch + scrape
puts "=== Branching from commit & scraping ===\n\n"

puts "[1/3] Branching..."
branch = client.branch_by_commit(commit_id, body: {})
vm_id = branch["vms"][0]["vm_id"]
puts "  VM: #{vm_id}"

puts "[2/3] Starting Chrome..."
port2, key2 = wait_ssh(client, vm_id)
ssh_exec(vm_id, port2, key2, <<~BASH)
  Xvfb :99 -screen 0 1280x800x24 &>/dev/null &
  sleep 1
  export DISPLAY=:99
  CHROME=$(find /root/.cache/puppeteer -name "chrome" -type f 2>/dev/null | head -1)
  $CHROME --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage \
      --remote-debugging-port=9222 --remote-debugging-address=0.0.0.0 \
      about:blank &>/dev/null &
  for i in $(seq 1 30); do curl -s http://127.0.0.1:9222/json/version && break; sleep 1; done
BASH

puts "[3/3] Connecting via Ferrum CDP...\n\n"
browser = Ferrum::Browser.new(url: "http://#{vm_id}.vm.vers.sh:9222")
page = browser.create_page
page.go_to("https://example.com")

title = page.title
puts "Title: #{title}"

links = page.evaluate(<<~JS)
  Array.from(document.querySelectorAll('a[href]'))
    .map(a => ({ text: a.textContent.trim(), href: a.href }))
JS
puts "Links (#{links.length}):"
links.each { |l| puts "  #{l['text']} → #{l['href']}" }

browser.quit

# Cleanup
puts "\nDeleting VM #{vm_id}..."
client.delete_vm(vm_id)
puts "Done."
