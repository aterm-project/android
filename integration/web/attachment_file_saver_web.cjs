/* Exercise the compiled Web File System Access adapter in Chromium. */

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const clientDir = path.join(root, 'apps/client');
const flutter = process.env.FLUTTER_BIN || 'flutter';
const chrome = process.env.CHROME_EXECUTABLE ||
  process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE || chromium.executablePath();
if (!fs.existsSync(chrome)) {
  throw new Error(
    'Chromium is not installed for Playwright. Run `npx playwright install chromium` in integration/web.',
  );
}

const result = spawnSync(flutter, [
  'test',
  '--platform',
  'chrome',
  'test/attachment_file_saver_web_test.dart',
], {
  cwd: clientDir,
  env: {
    ...process.env,
    CHROME_EXECUTABLE: chrome,
  },
  stdio: 'inherit',
});

if (result.error) throw result.error;
if (result.signal) {
  process.kill(process.pid, result.signal);
} else if (result.status !== 0) {
  process.exit(result.status || 1);
}
