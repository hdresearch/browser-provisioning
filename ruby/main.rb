#!/usr/bin/env ruby
# frozen_string_literal: true
# browser-provisioning / Ruby — vers-sdk + vers CLI + puppeteer-core (inside VM)
# VERS_API_KEY must be set. `vers` CLI must be on PATH.

require "vers_sdk"
require "json"
require "open3"

$active_vms = []
$client = nil

def cleanup_vms
  return if $active_vms.empty? || $client.nil?
  $active_vms.each do |vm|
    $stderr.puts "[cleanup] Deleting VM #{vm}..."
    $client.delete_vm(vm) rescue nil
  end
  $active_vms.clear
end

at_exit { cleanup_vms }
trap("INT")  { cleanup_vms; exit 1 }
trap("TERM") { cleanup_vms; exit 1 }

def vers_exec(vm_id, script, timeout: 600)
  out, err, st = Open3.capture3("vers", "exec", "-i", "-t", timeout.to_s, vm_id, "bash", stdin_data: script)
  $stderr.puts "  [vers exec exit=#{st.exitstatus}] #{err[0..300]}" unless st.success?
  out
end

def vers_wait(vm_id, max_sec: 120)
  deadline = Time.now + max_sec
  while Time.now < deadline
    begin
      return if vers_exec(vm_id, "echo ready", timeout: 10).include?("ready")
    rescue StandardError
    end
    sleep 3
  end
  raise "VM #{vm_id} not ready after #{max_sec}s"
end

INSTALL_SCRIPT = <<~'BASH'
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
BASH

SCRAPE_SCRIPT = <<~'BASH'
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
BASH

$client = VersSdk::VersSdkClient.new

puts "=== [Ruby] Building golden image ===\n\n"

puts "[1/4] Creating root VM..."
root = $client.create_new_root_vm(
  body: {"vm_config" => {"vcpu_count" => 2, "mem_size_mib" => 4096, "fs_size_mib" => 8192,
                          "kernel_name" => "default.bin", "image_name" => "default"}},
  params: (p = VersSdk::CreateNewRootVmParams.new; p.wait_boot = true; p)
)
build_vm = root["vm_id"]
$active_vms << build_vm
puts "  VM: #{build_vm}"

puts "[2/4] Waiting for VM..."
vers_wait(build_vm)

puts "[3/4] Installing Chromium..."
vers_exec(build_vm, INSTALL_SCRIPT)

puts "[4/4] Committing..."
commit = $client.commit_vm(build_vm, body: {})
commit_id = commit["commit_id"]
puts "  Commit: #{commit_id}"
$client.delete_vm(build_vm)
$active_vms.delete(build_vm)
puts "  Build VM deleted\n\n"

puts "=== Branching from commit & scraping ===\n\n"

puts "[1/3] Branching..."
branch = $client.branch_by_commit(commit_id, body: {})
vm_id = branch["vms"][0]["vm_id"]
$active_vms << vm_id
puts "  VM: #{vm_id}"

puts "[2/3] Waiting for VM..."
vers_wait(vm_id)

puts "[3/3] Starting Chrome & scraping inside VM...\n\n"
output = vers_exec(vm_id, SCRAPE_SCRIPT, timeout: 120)

output.strip.split("\n").each do |line|
  next unless line.start_with?("{")
  data = JSON.parse(line)
  puts "Title: #{data['title']}"
  puts "Links (#{data['links'].length}):"
  data["links"].each { |l| puts "  #{l['text']} → #{l['href']}" }
  break
end

$client.delete_vm(vm_id)
$active_vms.delete(vm_id)
puts "\nVM #{vm_id} deleted. Done."
