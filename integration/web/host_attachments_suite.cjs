/* Run every encrypted attachment recovery path against fresh server fixtures. */

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const scenarios = ['ack-loss', 'expired', 'process-kill'];
const testScript = path.join(__dirname, 'host_attachments.cjs');

for (const scenario of scenarios) {
  console.log(`\nWEB-ATTACH-01 upload recovery scenario: ${scenario}`);
  const result = spawnSync(process.execPath, [testScript], {
    cwd: path.resolve(__dirname, '../..'),
    env: {
      ...process.env,
      ATERMIUS_WEB_ATTACHMENT_UPLOAD_SCENARIO: scenario,
    },
    stdio: 'inherit',
  });
  if (result.error) throw result.error;
  if (result.signal) {
    process.kill(process.pid, result.signal);
    break;
  }
  if (result.status !== 0) process.exit(result.status || 1);
}
