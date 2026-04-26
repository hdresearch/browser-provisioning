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
