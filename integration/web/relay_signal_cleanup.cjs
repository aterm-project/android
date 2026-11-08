'use strict';

const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const script = path.join(__dirname, 'relay_terminal.cjs');
const tempPrefix = 'atermius-relay-web-';
const readinessMarkers = [
  'stage: isolated bastion and target SSHDs are ready',
  'stage: both restricted bastions and isolated target SSHDs are ready',
];

function temporaryFixtures() {
  return fs.readdirSync(os.tmpdir())
    .filter((name) => name.startsWith(tempPrefix))
    .sort();
}

function waitForSignalCleanup() {
  return new Promise((resolve, reject) => {
    const before = new Set(temporaryFixtures());
    const child = spawn(process.execPath, [script], {
      cwd: __dirname,
      stdio: ['ignore', 'pipe', 'pipe'],
      detached: true,
    });
    let stdoutTail = '';
    let reachedFixture = false;
    let sentSignal = false;
    let settled = false;

    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve(result);
    };

    const timer = setTimeout(() => {
      if (child.exitCode === null) child.kill('SIGTERM');
      const killTimer = setTimeout(() => {
        if (child.exitCode === null) child.kill('SIGKILL');
      }, 5000);
      killTimer.unref();
      finish(new Error('Relay signal-cleanup fixture timed out before bounded exit'));
    }, 240000);
    timer.unref();

    child.once('error', (error) => finish(error));
    child.stdout.on('data', (chunk) => {
      stdoutTail = `${stdoutTail}${chunk.toString('utf8')}`.slice(-4096);
      if (!sentSignal && readinessMarkers.some((marker) => stdoutTail.includes(marker))) {
        reachedFixture = true;
        sentSignal = true;
        child.kill('SIGINT');
      }
    });
    child.stderr.on('data', () => {});
    child.once('close', (code, signal) => {
      setTimeout(() => {
        const leftovers = temporaryFixtures().filter((name) => !before.has(name));
        try {
          assert.equal(reachedFixture, true, 'fixture did not reach the server + SSHD ready point');
          assert.equal(sentSignal, true, 'fixture did not receive SIGINT');
          assert.equal(code, 130, `harness exited with code ${code} (${signal || 'no signal'})`);
          assert.deepEqual(leftovers, [], 'Relay harness left its temporary fixture directory behind');
          finish(null, { interruptedAtReadyPoint: true, exitCode: code, temporaryFixturesRemoved: true });
        } catch (error) {
          finish(error);
        }
      }, 100);
    });
  });
}

waitForSignalCleanup().then((result) => {
  console.log('WEB-RELAY-CLEANUP passed:', JSON.stringify(result));
}).catch(() => {
  console.error('WEB-RELAY-CLEANUP failed: isolated Relay fixture did not clean up after SIGINT');
  process.exitCode = 1;
});
