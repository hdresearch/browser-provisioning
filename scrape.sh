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
