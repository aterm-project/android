/*
 * WEB-ADMIN-JOBS-01: verify the instance-admin durable job workflow in
 * Flutter Web against a disposable server. The administrator loads the durable
 * job list and submits maintenance and encrypted-backup jobs, including a
 * real maintenance lock-conflict failure, startup recovery after killed maintenance
 * and backup workers, and configured-key backup failure; a separately invited non-admin must not see
 * the card or use either endpoint. Only safe stage, status, and boolean
 * diagnostics are printed.
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const crypto = require('node:crypto');
const { selectServerModeIfChooser } = require('./server_mode.cjs');
const { spawn, spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const WEB_ROOT = path.join(ROOT, 'apps/client/build/web');
const SERVER_MANIFEST = path.join(ROOT, 'server/Cargo.toml');
const SERVER_BINARY = path.join(ROOT, 'server/target/debug/atermius-server');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;
const JOB_KEYS = [
  'job_id', 'request_id', 'action', 'archive_id', 'archive_source', 'status', 'requested_at',
  'started_at', 'finished_at', 'result_code', 'restore_stage_status',
];
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

let stage = 'preflight';
let tempRoot;
let serverProcess;
let debuggerProcess;
let browser;
let adminContext;
let memberContext;
let bootstrapToken;
let invitationToken;
let adminUsername;
let adminPassword;
let memberUsername;
let memberPassword;
let adminAccessToken;
let memberAccessToken;
let cleanupPromise;
let cleanupFailed = false;
let maintenanceLockProcess;
let maintenanceLockReadyPath;
let maintenanceLockReleasePath;
let interruptedAdminJobBreakpoint;
let backupKeyFilePath;
let backupKeyQuarantinePath;
let backupKeyGdbReleasePath;
let backupKeyExpectedDigest;
let backupKeyQuarantined = false;
const leakSentinels = [];
const safeApiStatuses = [];

function assertThat(condition, message) {
  if (!condition) {
    const error = new Error(message);
    error.safeAssertion = message;
    throw error;
  }
}

function setStage(value) {
  stage = value;
  console.log(`stage: ${value}`);
}

function reportStatus(assertion, status) {
  console.log(`assert: ${assertion}_http_status=${status}`);
}

function reportBoolean(assertion, value) {
  console.log(`assert: ${assertion}=${value}`);
}

function buildServer() {
  const result = spawnSync('cargo', ['build', '--locked', '--manifest-path', SERVER_MANIFEST], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 180000,
  });
  assertThat(!result.error && result.status === 0, 'isolated server build failed');
  assertThat(fs.existsSync(SERVER_BINARY), 'isolated server binary is unavailable');
}

async function unusedLoopbackPort() {
  const listener = net.createServer();
  await new Promise((resolve, reject) => {
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', resolve);
  });
  const port = listener.address().port;
  await new Promise((resolve, reject) => {
    listener.close((error) => error ? reject(error) : resolve());
  });
  return port;
}

async function waitForServer(baseUrl, child, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error('isolated server exited early');
    try {
      const response = await fetch(`${baseUrl}/health/ready`, {
        signal: AbortSignal.timeout(1200),
      });
      if (response.status === 200) return;
    } catch (_) {
      // Continue while the disposable loopback server starts.
    }
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error('isolated server readiness timed out');
}

function processGroupHasLiveMembers(groupId) {
  try {
    for (const entry of fs.readdirSync('/proc')) {
      if (!/^\d+$/.test(entry)) continue;
      let stat;
      try {
        stat = fs.readFileSync(`/proc/${entry}/stat`, 'utf8');
      } catch (error) {
        if (error.code === 'EACCES' || error.code === 'EPERM') return true;
        continue;
      }
      const closeParen = stat.lastIndexOf(')');
      if (closeParen < 0) continue;
      const fields = stat.slice(closeParen + 2).trim().split(/\s+/);
      if (Number(fields[2]) === groupId && fields[0] !== 'Z' && fields[0] !== 'X') {
        return true;
      }
    }
    return false;
  } catch (_) {
    try {
      process.kill(-groupId, 0);
      return true;
    } catch (error) {
      return error.code !== 'ESRCH';
    }
  }
}

function signalProcessGroup(groupId, signal) {
  try {
    process.kill(-groupId, signal);
  } catch (error) {
    if (error.code !== 'ESRCH') throw new Error('server process cleanup failed');
  }
}

async function waitForProcessGroupExit(groupId, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processGroupHasLiveMembers(groupId)) return true;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return !processGroupHasLiveMembers(groupId);
}

async function stopServerGroup(child) {
  if (!child || !Number.isInteger(child.pid)) return;
  const groupId = child.pid;
  if (!processGroupHasLiveMembers(groupId)) return;
  signalProcessGroup(groupId, 'SIGTERM');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  signalProcessGroup(groupId, 'SIGKILL');
  if (await waitForProcessGroupExit(groupId, 2500)) return;
  throw new Error('server process group did not stop');
}

function posixShellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

async function armMaintenanceLockFailure(dataDir, privateRoot, timeoutMs = 20000) {
  assertThat(process.platform === 'linux',
    'deterministic maintenance failure requires the Linux file-lock implementation');
  const flockVersion = spawnSync('flock', ['--version'], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 5000,
  });
  assertThat(!flockVersion.error && flockVersion.status === 0,
    'deterministic maintenance failure requires the flock utility');

  const lockPath = path.join(dataDir, 'maintenance.lock');
  const readyPath = path.join(privateRoot, `maintenance-lock-ready-${crypto.randomUUID()}`);
  const releasePath = path.join(privateRoot, `maintenance-lock-release-${crypto.randomUUID()}`);
  const lockMetadata = fs.lstatSync(lockPath);
  assertThat(lockMetadata.isFile() && !lockMetadata.isSymbolicLink() &&
      (lockMetadata.mode & 0o777) === 0o600,
    'isolated maintenance lock file was not a private regular file');
  assertThat(!fs.existsSync(readyPath) && !fs.existsSync(releasePath),
    'maintenance lock helper markers already existed');
  maintenanceLockReadyPath = readyPath;
  maintenanceLockReleasePath = releasePath;

  const holdCommand = `touch -- ${posixShellQuote(readyPath)}; ` +
    `while [ ! -e ${posixShellQuote(releasePath)} ]; do sleep 0.05; done`;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const child = spawn('flock', [
      '--exclusive', '--nonblock', lockPath, '/bin/sh', '-c', holdCommand,
    ], {
      cwd: ROOT,
      detached: true,
      stdio: 'ignore',
    });
    maintenanceLockProcess = child;
    let spawnError;
    let closed = false;
    child.once('error', (error) => { spawnError = error; });
    child.once('close', () => { closed = true; });

    while (Date.now() < deadline && !closed && !fs.existsSync(readyPath)) {
      if (spawnError) break;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    if (spawnError) {
      maintenanceLockProcess = undefined;
      throw new Error('flock helper could not start');
    }
    if (fs.existsSync(readyPath) && !closed) {
      assertThat(child.exitCode === null && child.signalCode === null,
        'maintenance lock helper exited immediately after reporting readiness');
      return { lockPath, readyPath, releasePath, process: child };
    }

    maintenanceLockProcess = undefined;
    if (!closed) {
      try {
        await stopServerGroup(child);
      } catch (_) {
        throw new Error('maintenance lock acquisition helper could not be stopped');
      }
    }
    if (Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 50));
  }
  maintenanceLockReadyPath = undefined;
  maintenanceLockReleasePath = undefined;
  throw new Error('isolated maintenance lock was not acquired before the timeout');
}

async function waitForChildClose(child, timeoutMs = 3000) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return true;
  return new Promise((resolve) => {
    let settled = false;
    const finish = (closed) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.removeListener('close', onClose);
      resolve(closed);
    };
    const onClose = () => finish(true);
    const timer = setTimeout(() => finish(false), timeoutMs);
    child.once('close', onClose);
    if (child.exitCode !== null || child.signalCode !== null) finish(true);
  });
}

async function releaseMaintenanceLockHelper() {
  const child = maintenanceLockProcess;
  if (!child) {
    maintenanceLockReadyPath = undefined;
    maintenanceLockReleasePath = undefined;
    return;
  }
  if (maintenanceLockReleasePath && !fs.existsSync(maintenanceLockReleasePath)) {
    fs.writeFileSync(maintenanceLockReleasePath, 'release', { mode: 0o600 });
  }
  if (!(await waitForChildClose(child, 3000))) {
    await stopServerGroup(child);
  }
  maintenanceLockProcess = undefined;
  maintenanceLockReadyPath = undefined;
  maintenanceLockReleasePath = undefined;
}

function readBusinessDatabaseDigest(databasePath) {
  // The live browser legitimately renews one-use notification tickets and
  // presence heartbeats during acceptance. Keep this digest focused on
  // durable account/Vault configuration and content rows.
  const code = [
    'import hashlib, json, sqlite3, sys',
    "connection = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True, timeout=10)",
    "tables = [row[0] for row in connection.execute(\"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('instance_admin_jobs','audit_events','notification_tickets','vault_presence','vault_presence_heartbeat_limits') ORDER BY name\")]",
    'def quote(identifier):',
    '    return chr(34) + identifier.replace(chr(34), chr(34) + chr(34)) + chr(34)',
    'def stable(value):',
    '    if isinstance(value, bytes):',
    '        return {"bytes_sha256": hashlib.sha256(value).hexdigest(), "bytes_length": len(value)}',
    '    return value',
    'snapshot = {}',
    'table_hashes = {}',
    'for table in tables:',
    '    columns = connection.execute("PRAGMA table_info(" + quote(table) + ")").fetchall()',
    '    rows = connection.execute("SELECT * FROM " + quote(table)).fetchall()',
    '    stable_rows = [tuple(stable(value) for value in row) for row in rows]',
    '    table_snapshot = {"columns": [(column[1], column[2], column[3], column[5]) for column in columns], "rows": sorted(stable_rows, key=repr)}',
    '    snapshot[table] = table_snapshot',
    '    table_hashes[table] = hashlib.sha256(json.dumps(table_snapshot, sort_keys=True, separators=(",", ":")).encode()).hexdigest()',
    'encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()',
    'summary = {"sha256": hashlib.sha256(encoded).hexdigest(), "table_count": len(tables), "table_hashes": table_hashes}',
    'print(json.dumps(summary, sort_keys=True, separators=(",", ":")))',
    'connection.close()',
  ].join('\n');
  const result = spawnSync('python3', ['-c', code, databasePath], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 15000,
    maxBuffer: 65536,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only business database digest could not be computed');
  let summary;
  try {
    summary = JSON.parse((result.stdout || '').trim());
  } catch (_) {
    summary = null;
  }
  result.stdout = '';
  assertThat(exactKeys(summary, ['sha256', 'table_count', 'table_hashes']) &&
      /^[0-9a-f]{64}$/.test(summary.sha256) && Number.isInteger(summary.table_count) &&
      summary.table_count > 0 && summary.table_hashes &&
      Object.values(summary.table_hashes).every((hash) => /^[0-9a-f]{64}$/.test(hash)),
    'read-only business database digest summary was invalid');
  return summary;
}

function restoreDisposableBackupKey() {
  if (!backupKeyFilePath || !backupKeyExpectedDigest) return;
  if (backupKeyQuarantined) {
    assertThat(backupKeyQuarantinePath && fs.existsSync(backupKeyQuarantinePath),
      'disposable backup key was not available for restoration');
    fs.renameSync(backupKeyQuarantinePath, backupKeyFilePath);
    backupKeyQuarantined = false;
  }
  const metadata = fs.lstatSync(backupKeyFilePath);
  const digest = crypto.createHash('sha256').update(fs.readFileSync(backupKeyFilePath)).digest('hex');
  assertThat(metadata.isFile() && !metadata.isSymbolicLink() &&
      (metadata.mode & 0o777) === 0o600 && digest === backupKeyExpectedDigest,
    'disposable backup key was not restored exactly');
}

async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    bootstrapToken = undefined;
    invitationToken = undefined;
    adminUsername = undefined;
    adminPassword = undefined;
    memberUsername = undefined;
    memberPassword = undefined;
    adminAccessToken = undefined;
    memberAccessToken = undefined;
    leakSentinels.length = 0;
    try {
      if (adminContext) await adminContext.close().catch(() => {});
      if (memberContext) await memberContext.close().catch(() => {});
      if (browser) await browser.close().catch(() => {});
    } catch (_) {
      cleanupFailed = true;
    }
    if (interruptedAdminJobBreakpoint && serverProcess) {
      try {
        await killPausedAdminJobWorker(serverProcess, interruptedAdminJobBreakpoint);
      } catch (_) {
        cleanupFailed = true;
      }
    }
    if (backupKeyQuarantined && backupKeyGdbReleasePath &&
        !fs.existsSync(backupKeyGdbReleasePath)) {
      try {
        fs.writeFileSync(backupKeyGdbReleasePath, 'resume');
      } catch (_) {
        cleanupFailed = true;
      }
    }
    if (maintenanceLockProcess) {
      // Keep a stranded maintenance worker from proceeding after an aborted
      // test releases the fixture lock; the server is disposable and will be
      // restarted by the next runner invocation.
      try {
        if (serverProcess) {
          await stopServerGroup(serverProcess);
          serverProcess = undefined;
        }
      } catch (_) {
        cleanupFailed = true;
      }
      try {
        await releaseMaintenanceLockHelper();
      } catch (_) {
        cleanupFailed = true;
      }
    }
    for (const child of [serverProcess, debuggerProcess]) {
      try {
        await stopServerGroup(child);
      } catch (_) {
        cleanupFailed = true;
      }
    }
    try {
      restoreDisposableBackupKey();
    } catch (_) {
      cleanupFailed = true;
    }
    if (tempRoot) {
      try {
        fs.rmSync(tempRoot, { recursive: true, force: true });
        if (fs.existsSync(tempRoot)) cleanupFailed = true;
      } catch (_) {
        cleanupFailed = true;
      }
    }
  })();
  return cleanupPromise;
}

process.once('SIGINT', () => {
  void cleanup().finally(() => process.exit(130));
});
process.once('SIGTERM', () => {
  void cleanup().finally(() => process.exit(143));
});

async function field(page, label) {
  const locator = page.locator(
    `input[aria-label*=${JSON.stringify(label)}],textarea[aria-label*=${JSON.stringify(label)}]`,
  ).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function button(page, label) {
  const locator = page.getByRole('button', { name: label, exact: true }).first();
  await selectServerModeIfChooser(page, locator);
  await locator.waitFor({ state: 'visible', timeout: 20000 });
  return locator;
}

async function click(page, label) {
  await (await button(page, label)).click();
}

async function fill(page, label, value) {
  const locator = await field(page, label);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await locator.click();
    await page.waitForTimeout(100);
    await locator.press('Control+A');
    await page.waitForTimeout(50);
    await locator.pressSequentially(value, { delay: 35 });
    await page.waitForTimeout(150);
    if (await locator.inputValue() !== value) continue;
    await locator.press('Tab');
    await page.waitForTimeout(100);
    if (await locator.inputValue() === value) return;
  }
  throw new Error('a visible form field did not retain its input');
}

async function waitFor(predicate, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected UI or API state did not appear');
}

async function waitForFile(filePath, timeoutMs, description) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fs.existsSync(filePath)) return;
    if (debuggerProcess && debuggerProcess.exitCode !== null) break;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(description);
}

async function armManualBackupFailureBreakpoint(privateRoot) {
  assertThat(serverProcess && Number.isInteger(serverProcess.pid),
    'isolated server PID was unavailable for deterministic backup failure');
  const gdbVersion = spawnSync('gdb', ['--version'], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 5000,
  });
  assertThat(!gdbVersion.error && gdbVersion.status === 0,
    'deterministic backup failure requires GDB with ptrace access');

  const readyPath = path.join(privateRoot, 'backup-gdb-ready');
  const hitPath = path.join(privateRoot, 'backup-gdb-hit');
  const releasePath = path.join(privateRoot, 'backup-gdb-release');
  backupKeyGdbReleasePath = releasePath;
  const scriptPath = path.join(privateRoot, 'backup-worker.gdb');
  const sourcePath = path.join(ROOT, 'server/src/backup.rs');
  const sourceLines = fs.readFileSync(sourcePath, 'utf8').split('\n');
  const breakpointLine = sourceLines.findIndex((line) =>
    line.trim() === 'if let Err(error) = configured_backup_paths(&state.config) {') + 1;
  assertThat(breakpointLine > 0,
    'configured backup key validation breakpoint was not found');
  const escapedBreakpoint = `"${`${sourcePath}:${breakpointLine}`
    .replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
  fs.writeFileSync(scriptPath,
    `set pagination off\nset confirm off\nbreak ${escapedBreakpoint}\n` +
      'commands 1\n  silent\n  disable 1\n' +
      `  shell touch -- ${posixShellQuote(hitPath)}\n` +
      `  shell while [ ! -e ${posixShellQuote(releasePath)} ]; do sleep 0.05; done\n` +
      '  continue\nend\n' +
      `shell touch -- ${posixShellQuote(readyPath)}\ncontinue\n`,
    { flag: 'wx', mode: 0o600 });
  debuggerProcess = spawn('gdb', [
    '--quiet', '--batch', '--pid', String(serverProcess.pid), '--command', scriptPath,
  ], {
    cwd: ROOT,
    detached: true,
    stdio: 'ignore',
  });
  assertThat(Number.isInteger(debuggerProcess.pid),
    'debugger did not start for deterministic backup failure');
  await waitForFile(readyPath, 15000,
    'debugger could not attach and arm the backup worker breakpoint');
  return { hitPath, releasePath };
}

async function armAdminJobInterruptedBreakpoint(privateRoot, action) {
  assertThat(serverProcess && Number.isInteger(serverProcess.pid),
    'isolated server PID was unavailable for admin job interruption');
  assertThat(['maintenance', 'backup'].includes(action),
    'admin job interruption action was unsupported');
  const gdbVersion = spawnSync('gdb', ['--version'], {
    cwd: ROOT,
    stdio: 'ignore',
    timeout: 5000,
  });
  assertThat(!gdbVersion.error && gdbVersion.status === 0,
    'real admin job interruption requires GDB with ptrace access');

  const readyPath = path.join(privateRoot, `${action}-interrupt-gdb-ready`);
  const hitPath = path.join(privateRoot, `${action}-interrupt-gdb-hit`);
  const releasePath = path.join(privateRoot, `${action}-interrupt-gdb-release`);
  const scriptPath = path.join(privateRoot, `${action}-worker-interrupt.gdb`);
  const sourcePath = path.join(ROOT, 'server/src/admin.rs');
  const sourceLines = fs.readFileSync(sourcePath, 'utf8').split('\n');
  const breakpointLine = sourceLines.findIndex((line) =>
    line.trim() === 'let succeeded = match requester.action {') + 1;
  assertThat(breakpointLine > 0,
    'admin job worker post-start breakpoint was not found');
  const escapedBreakpoint = `"${`${sourcePath}:${breakpointLine}`
    .replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
  fs.writeFileSync(scriptPath,
    `set pagination off\nset confirm off\nbreak ${escapedBreakpoint}\n` +
      'commands 1\n  silent\n  disable 1\n' +
      `  shell touch -- ${posixShellQuote(hitPath)}\n` +
      `  shell while [ ! -e ${posixShellQuote(releasePath)} ]; do sleep 0.05; done\n` +
      '  continue\nend\n' +
      `shell touch -- ${posixShellQuote(readyPath)}\ncontinue\n`,
    { flag: 'wx', mode: 0o600 });
  debuggerProcess = spawn('gdb', [
    '--quiet', '--batch', '--pid', String(serverProcess.pid), '--command', scriptPath,
  ], {
    cwd: ROOT,
    detached: true,
    stdio: 'ignore',
  });
  assertThat(Number.isInteger(debuggerProcess.pid),
    'debugger did not start for admin job interruption');
  await waitForFile(readyPath, 15000,
    'debugger could not attach and arm the admin job worker breakpoint');
  return { action, hitPath, releasePath };
}

async function killPausedAdminJobWorker(child, breakpoint) {
  assertThat(child && Number.isInteger(child.pid) && breakpoint?.releasePath,
    'paused admin job server was unavailable for forced interruption');
  signalProcessGroup(child.pid, 'SIGKILL');
  // GDB is waiting inside the breakpoint command while the server is stopped.
  // Release its command after the signal is queued so ptrace can observe exit.
  fs.writeFileSync(breakpoint.releasePath, 'release', { mode: 0o600 });
  assertThat(await waitForProcessGroupExit(child.pid, 10000),
    'paused admin job server process group did not exit after SIGKILL');
  if (debuggerProcess) {
    await stopServerGroup(debuggerProcess);
    debuggerProcess = undefined;
  }
  assertThat(await waitForChildClose(child, 10000),
    'paused admin job server did not exit after SIGKILL');
  assertThat(child.signalCode === 'SIGKILL',
    'admin job worker process was not terminated by SIGKILL');
  serverProcess = undefined;
  interruptedAdminJobBreakpoint = undefined;
}

function readAdminJobBeforeRestart(databasePath, jobId) {
  const code = [
    'import json, sqlite3, sys',
    "connection = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True, timeout=10)",
    "row = connection.execute('SELECT request_id,action,status,started_at,finished_at,result_code FROM instance_admin_jobs WHERE job_id=?', (sys.argv[2],)).fetchone()",
    "print(json.dumps(None if row is None else dict(zip(('request_id','action','status','started_at','finished_at','result_code'), row)), separators=(',', ':'))) ",
    'connection.close()',
  ].join('\n');
  const result = spawnSync('python3', ['-c', code, databasePath, jobId], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 10000,
    maxBuffer: 2048,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0,
    'read-only interrupted-job snapshot could not be read');
  let snapshot;
  try {
    snapshot = JSON.parse((result.stdout || '').trim());
  } catch (_) {
    snapshot = null;
  }
  result.stdout = '';
  assertThat(exactKeys(snapshot, [
    'request_id', 'action', 'status', 'started_at', 'finished_at', 'result_code',
  ]), 'read-only interrupted-job snapshot was incomplete');
  return snapshot;
}

async function waitForAdminJobTerminal(baseUrl, token, jobId, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const response = await directApi(baseUrl, 'GET', '/api/v1/admin/jobs?limit=50&offset=0', {
      token,
    });
    assertThat(response.status === 200,
      'administrator could not read the durable backup job');
    const jobs = validateJobsPage(response.body);
    const job = jobs.find((item) => item.job_id === jobId);
    assertThat(job, 'durable backup job was absent from the refreshed page');
    if (['succeeded', 'failed', 'interrupted'].includes(job.status)) return job;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('manual backup job did not reach a durable terminal state');
}

async function scrollUntilVisibleSemanticText(page, needle, maxSteps = 24) {
  for (let step = 0; step <= maxSteps; step += 1) {
    if (await hasVisibleSemanticText(page, needle)) return;
    if (step === maxSteps) break;
    await page.mouse.move(900, 850);
    await page.mouse.wheel(0, 750);
    await page.waitForTimeout(60);
  }
  const error = new Error('expected settings panel did not enter the visible area');
  error.safeAssertion = error.message;
  throw error;
}

async function hasVisibleSemanticText(page, needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    const visibleText = nodes.filter((element) => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' &&
        Number(style.opacity) !== 0 && rect.width > 0 && rect.height > 0;
    }).map((element) => {
      const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`;
    }).join('\n');
    return visibleText.includes(expected);
  }, needle);
}

async function hasSemanticText(page, needle) {
  return page.evaluate((expected) => {
    const nodes = [...document.querySelectorAll('flt-semantics, flt-semantics *')];
    return nodes.some((element) => {
      const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
      return `${element.textContent || ''}\n${attributes}`.includes(expected);
    });
  }, needle);
}

async function pageVisibleText(page) {
  return page.evaluate(() => {
    const semantics = [...document.querySelectorAll('flt-semantics, flt-semantics *')]
      .map((element) => {
        const attributes = [...element.attributes].map((attribute) => attribute.value).join('\n');
        return `${element.textContent || ''}\n${attributes}`;
      }).join('\n');
    return `${document.body.innerText || ''}\n${semantics}`;
  });
}

function cliToken(args, serverEnv, description) {
  const result = spawnSync(SERVER_BINARY, args, {
    cwd: ROOT,
    env: serverEnv,
    encoding: 'utf8',
    timeout: 30000,
    maxBuffer: 4096,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  assertThat(!result.error && result.status === 0, `isolated ${description} failed`);
  const token = (result.stdout || '').trim().split(/\s+/).at(-1);
  result.stdout = '';
  assertThat(typeof token === 'string' && token.length >= 40,
    `isolated ${description} credential is unavailable`);
  leakSentinels.push(token);
  return token;
}

async function configurePage(page, baseUrl) {
  await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await waitFor(() => page.evaluate(() =>
    typeof window.sodium?.ready?.then === 'function' &&
    Boolean(document.querySelector('flt-semantics-placeholder'))), 30000);
  await page.evaluate(async () => { await window.sodium.ready; });
  await page.locator('flt-semantics-placeholder').evaluate((element) => element.click());
  await waitFor(() => page.evaluate(() => document.querySelectorAll('flt-semantics').length > 0), 15000);
  await fill(page, 'Server URL', baseUrl);
  await click(page, 'Connect securely');
}

function apiRoute(request) {
  try {
    const pathname = new URL(request.url()).pathname;
    if (pathname === '/api/v1/auth/register') return 'register';
    if (pathname === '/api/v1/admin/jobs') return 'admin-jobs';
    if (pathname === '/api/v1/admin/audit') return 'admin-audit';
    if (pathname === '/api/v1/admin/backup-status') return 'backup-status';
  } catch (_) {
    // Ignore browser-internal requests.
  }
  return null;
}

function trackApi(page, events) {
  const byRequest = new WeakMap();
  let requestSequence = 0;
  page.on('request', (request) => {
    const route = apiRoute(request);
    if (!route) return;
    let body = null;
    if (route === 'admin-jobs' && request.method() === 'POST') {
      try {
        body = request.postDataJSON();
      } catch (_) {
        body = null;
      }
    }
    const url = new URL(request.url());
    byRequest.set(request, {
      route,
      requestSequence: ++requestSequence,
      method: request.method(),
      hasBearer: (request.headers().authorization || '').startsWith('Bearer '),
      pathname: url.pathname,
      query: Object.fromEntries(url.searchParams.entries()),
      body,
    });
  });
  page.on('response', (response) => {
    const metadata = byRequest.get(response.request());
    if (!metadata) return;
    events.push({
      ...metadata,
      status: response.status(),
      jsonContentType: /^application\/json(?:\s*;|$)/i.test(
        response.headers()['content-type'] || '',
      ),
      sequence: events.length,
      payloadPromise: response.json().catch(() => null),
    });
    safeApiStatuses.push({ route: metadata.route, status: response.status() });
    if (safeApiStatuses.length > 20) safeApiStatuses.shift();
  });
  return () => requestSequence;
}

async function waitForEvent(events, predicate, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const event = events.find(predicate);
    if (event) return event;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error('expected API response did not arrive');
}

function exactKeys(value, expected) {
  return value && typeof value === 'object' && !Array.isArray(value) &&
    JSON.stringify(Object.keys(value).sort()) === JSON.stringify([...expected].sort());
}

function assertNoSecretOrIpFields(value) {
  const forbiddenKey = /(hash|ip|address|password|secret|verifier|envelope|ciphertext|token|filesystem|path)/i;
  const ipv4 = /\b(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}\b/;
  const visit = (item) => {
    if (Array.isArray(item)) {
      item.forEach(visit);
      return;
    }
    if (!item || typeof item !== 'object') return;
    for (const [key, child] of Object.entries(item)) {
      assertThat(!forbiddenKey.test(key), 'admin job metadata exposed a forbidden field');
      visit(child);
    }
  };
  visit(value);
  assertThat(!ipv4.test(JSON.stringify(value)), 'admin job metadata exposed an IP address');
}

function assertNoLeaks(value) {
  const serialized = typeof value === 'string' ? value : JSON.stringify(value);
  for (const secret of leakSentinels) {
    if (secret && secret.length >= 8) {
      assertThat(!serialized.includes(secret), 'a response or rendered view exposed a credential');
    }
  }
  const internalText = /\/(?:root|tmp|var|home|opt|usr|workspace)\/|\b[A-Z]:\\(?:Users|Windows|Program Files)\\|(?:SQLite|sqlx|tokio::|panic at|stack trace|backtrace|internal server error|no such table)/i;
  assertThat(!internalText.test(serialized), 'a response or rendered view exposed internal server details');
  if (tempRoot) assertThat(!serialized.includes(tempRoot), 'a response or rendered view exposed the server data path');
}

function validateJob(job) {
  assertThat(exactKeys(job, JOB_KEYS), 'admin job metadata fields changed');
  assertThat(UUID_PATTERN.test(job.job_id) && UUID_PATTERN.test(job.request_id),
    'admin job identifiers were not canonical UUIDs');
  assertThat(['maintenance', 'backup'].includes(job.action), 'admin job action was unexpected');
  assertThat(job.archive_id === null, 'maintenance or backup job unexpectedly exposed a source archive ID');
  assertThat(job.archive_source === null,
    'maintenance or backup job unexpectedly exposed a restore archive source');
  assertThat(job.restore_stage_status === null,
    'maintenance or backup job unexpectedly exposed a restore-stage state');
  assertThat(['queued', 'running', 'succeeded', 'failed', 'interrupted'].includes(job.status),
    'admin job status was invalid');
  const timestamp = (value) => typeof value === 'string' &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    !Number.isNaN(Date.parse(value));
  assertThat(timestamp(job.requested_at), 'admin job request timestamp was invalid');
  assertThat(job.started_at === null || timestamp(job.started_at), 'admin job start timestamp was invalid');
  assertThat(job.finished_at === null || timestamp(job.finished_at), 'admin job finish timestamp was invalid');
  const resultCodes = job.action === 'backup'
    ? ['completed', 'backup_failed', 'interrupted']
    : ['completed', 'maintenance_failed', 'interrupted'];
  assertThat(job.result_code === null || resultCodes.includes(job.result_code),
    'admin job result code was invalid');
  if (job.status === 'queued') {
    assertThat(job.started_at === null && job.finished_at === null && job.result_code === null,
      'queued maintenance job had terminal metadata');
  } else if (job.status === 'running') {
    assertThat(job.started_at !== null && job.finished_at === null && job.result_code === null,
      'running maintenance job had inconsistent timestamps');
  } else if (job.status === 'succeeded') {
    assertThat(job.started_at !== null && job.finished_at !== null && job.result_code === 'completed',
      'succeeded maintenance job had inconsistent terminal metadata');
  } else if (job.status === 'failed') {
    const expectedFailure = job.action === 'backup' ? 'backup_failed' : 'maintenance_failed';
    assertThat(job.started_at !== null && job.finished_at !== null && job.result_code === expectedFailure,
      'failed admin job had inconsistent terminal metadata');
  } else {
    assertThat(job.finished_at !== null && job.result_code === 'interrupted',
      'interrupted maintenance job had inconsistent terminal metadata');
  }
  assertNoSecretOrIpFields(job);
  assertNoLeaks(job);
  return job;
}

function validateJobsPage(payload, expectedTotal, jsonContentType = false) {
  const pageShapeValid = exactKeys(payload, ['jobs', 'total']) &&
    Array.isArray(payload.jobs) && Number.isInteger(payload.total) && payload.total >= 0;
  const safeKeys = payload && typeof payload === 'object'
    ? Object.keys(payload).filter((key) => ['jobs', 'total', 'error', 'code'].includes(key)).sort().join(',')
    : 'none';
  const safeJobCount = Array.isArray(payload?.jobs) ? payload.jobs.length : -1;
  assertThat(pageShapeValid,
    `admin jobs page shape was invalid (keys=${safeKeys}, totalType=${typeof payload?.total}, jobCount=${safeJobCount}, jsonContentType=${jsonContentType})`);
  assertNoSecretOrIpFields(payload);
  assertNoLeaks(payload);
  for (const job of payload.jobs) validateJob(job);
  if (expectedTotal !== undefined) {
    assertThat(payload.total === expectedTotal && payload.jobs.length === expectedTotal,
      'maintenance job list did not contain the expected durable row count');
  }
  return payload.jobs;
}

async function directApi(baseUrl, method, pathname, { token, body } = {}) {
  const response = await fetch(`${baseUrl}${pathname}`, {
    method,
    headers: {
      accept: 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'content-type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15000),
  });
  const payload = await response.json().catch(() => null);
  assertNoLeaks(payload);
  return { status: response.status, body: payload };
}

function validateAuditPage(payload) {
  assertThat(exactKeys(payload, ['events', 'next_cursor', 'has_more']) &&
      Array.isArray(payload.events) && typeof payload.has_more === 'boolean' &&
      (payload.next_cursor === null || typeof payload.next_cursor === 'string'),
    'admin audit page shape was invalid');
  assertNoSecretOrIpFields(payload);
  assertNoLeaks(payload);
  const expectedKeys = [
    'event_id', 'scope', 'actor_user_id', 'actor_device_id', 'action', 'resource_type',
    'resource_id', 'result', 'occurred_at', 'source',
  ];
  for (const event of payload.events) {
    assertThat(exactKeys(event, expectedKeys), 'admin audit event fields changed');
    assertThat(event.scope === 'instance' && /^\d+$/.test(event.event_id) &&
        ['success', 'failure'].includes(event.result) &&
        ['api', 'maintenance'].includes(event.source),
      'admin audit event metadata was invalid');
    assertThat(event.resource_id === null || /^[0-9a-f]{64}$/.test(event.resource_id),
      'admin audit event exposed an unprotected resource identifier');
  }
  return payload.events;
}

async function createAdminProfile(page, baseUrl, events) {
  await configurePage(page, baseUrl);
  await field(page, 'Owner email');
  await fill(page, 'Owner email', adminUsername);
  await fill(page, 'Master password · 12+ characters', adminPassword);
  await fill(page, 'Confirm master password', adminPassword);
  await fill(page, 'One-time bootstrap token', bootstrapToken);
  await fill(page, 'Device name', 'Admin jobs acceptance');
  await fill(page, 'First Vault', 'Admin jobs acceptance');
  const start = events.length;
  await click(page, 'Create owner account');
  bootstrapToken = undefined;
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.account_id === 'string' && typeof payload?.device_id === 'string' &&
      typeof payload?.access_token === 'string',
    'allowlisted administrator registration response was incomplete');
  leakSentinels.push(adminPassword, payload.access_token);
  return {
    status: registration.status,
    accountId: payload.account_id,
    deviceId: payload.device_id,
    accessToken: payload.access_token,
  };
}

async function createMemberProfile(page, baseUrl, events) {
  await configurePage(page, baseUrl);
  await field(page, 'Email or username');
  await click(page, 'Have an instance invitation? Create account');
  await field(page, 'Email on the invitation');
  await fill(page, 'Email on the invitation', memberUsername);
  await fill(page, 'Master password · 12+ characters', memberPassword);
  await fill(page, 'Confirm master password', memberPassword);
  await fill(page, 'Instance invitation token', invitationToken);
  invitationToken = undefined;
  await fill(page, 'Device name', 'Non-admin jobs acceptance');
  await fill(page, 'First Vault', 'Non-admin jobs acceptance');
  const start = events.length;
  await click(page, 'Create invited account');
  await (await button(page, 'Add host')).waitFor({ state: 'visible', timeout: 45000 });
  const registration = await waitForEvent(events,
    (event) => event.route === 'register' && event.sequence >= start);
  const payload = await registration.payloadPromise;
  assertThat(registration.status >= 200 && registration.status < 300 &&
      typeof payload?.access_token === 'string',
    'invited non-admin registration response was incomplete');
  leakSentinels.push(memberPassword, payload.access_token);
  return { status: registration.status, accessToken: payload.access_token };
}

function adminJobsEvent(events, method, sequence = 0) {
  return (event) => event.route === 'admin-jobs' && event.method === method &&
    event.requestSequence > sequence;
}

async function main() {
  for (const asset of ['index.html', 'main.dart.js', 'drift_worker.js', 'sqlite3.wasm']) {
    assertThat(fs.existsSync(path.join(WEB_ROOT, asset)), 'compiled Flutter Web release is incomplete');
  }

  setStage('isolated server build');
  buildServer();

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-admin-jobs-'));
    fs.chmodSync(tempRoot, 0o700);
    const dataDir = path.join(tempRoot, 'data');
    fs.mkdirSync(dataDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(dataDir, 0o700);
    const maintenanceLockPath = path.join(dataDir, 'maintenance.lock');
    fs.writeFileSync(maintenanceLockPath, Buffer.alloc(0), { flag: 'wx', mode: 0o600 });
    fs.chmodSync(maintenanceLockPath, 0o600);
    const backupArchiveDir = path.join(tempRoot, 'backup-archives');
    fs.mkdirSync(backupArchiveDir, { recursive: true, mode: 0o700 });
    fs.chmodSync(backupArchiveDir, 0o700);
    const backupKeyFile = path.join(tempRoot, 'operator-backup.key');
    const backupKeyMaterial = crypto.randomBytes(32);
    backupKeyFilePath = backupKeyFile;
    backupKeyQuarantinePath = path.join(tempRoot, 'operator-backup.key-held');
    backupKeyExpectedDigest = crypto.createHash('sha256').update(backupKeyMaterial).digest('hex');
    assertThat(path.dirname(backupKeyQuarantinePath) === tempRoot,
      'backup key quarantine escaped the disposable fixture');
    fs.writeFileSync(backupKeyFile, backupKeyMaterial, { mode: 0o600 });
    backupKeyMaterial.fill(0);
    fs.chmodSync(backupKeyFile, 0o600);
    const databasePath = path.join(dataDir, 'atermius.db');
    const port = await unusedLoopbackPort();
    const baseUrl = `http://127.0.0.1:${port}`;
    adminUsername = `web-admin-jobs-${crypto.randomUUID().slice(0, 8)}@example.test`;
    adminPassword = `Admin-${crypto.randomBytes(32).toString('base64url')}`;
    memberUsername = `web-jobs-member-${crypto.randomUUID().slice(0, 8)}@example.test`;
    memberPassword = `Member-${crypto.randomBytes(32).toString('base64url')}`;
    leakSentinels.push(adminPassword, memberPassword, tempRoot, databasePath);
    const serverEnv = {
      ...process.env,
      ATERMIUS_BIND: `127.0.0.1:${port}`,
      ATERMIUS_DATA_DIR: dataDir,
      ATERMIUS_BACKUP_ARCHIVE_DIR: backupArchiveDir,
      ATERMIUS_BACKUP_KEY_FILE: backupKeyFile,
      ATERMIUS_DATABASE_URL: `sqlite://${databasePath}?mode=rwc`,
      ATERMIUS_WEB_DIR: WEB_ROOT,
      ATERMIUS_PUBLIC_ORIGIN: baseUrl,
      ATERMIUS_REGISTRATION_OPEN: 'false',
      ATERMIUS_RELAY_ENABLED: 'false',
      ATERMIUS_ADMIN_USERNAMES: adminUsername,
      RUST_LOG: 'off',
    };
    const adminEvents = [];
    const memberEvents = [];
    let pageErrors = 0;

    setStage('start disposable allowlisted instance');
    serverProcess = spawn(SERVER_BINARY, ['serve'], {
      cwd: ROOT,
      env: serverEnv,
      detached: true,
      stdio: 'ignore',
    });
    await waitForServer(baseUrl, serverProcess);
    bootstrapToken = cliToken(['bootstrap'], serverEnv, 'bootstrap');

    setStage('launch isolated Chromium profiles');
    const launchOptions = { headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    adminContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    memberContext = await browser.newContext({ locale: 'en-US', viewport: { width: 1440, height: 1000 } });
    const adminPage = await adminContext.newPage();
    const memberPage = await memberContext.newPage();
    adminPage.on('pageerror', () => { pageErrors += 1; });
    memberPage.on('pageerror', () => { pageErrors += 1; });
    const adminRequestSequence = trackApi(adminPage, adminEvents);
    trackApi(memberPage, memberEvents);

    setStage('register allowlisted instance administrator');
    const admin = await createAdminProfile(adminPage, baseUrl, adminEvents);
    adminAccessToken = admin.accessToken;
    reportStatus('admin_registration', admin.status);

    setStage('create separately invited non-admin profile');
    invitationToken = cliToken(
      ['create-account-invite', '--username', memberUsername], serverEnv, 'account invitation');
    const member = await createMemberProfile(memberPage, baseUrl, memberEvents);
    memberAccessToken = member.accessToken;
    reportStatus('non_admin_registration', member.status);

    setStage('verify non-admin maintenance card gating');
    await click(memberPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(memberPage, 'Workspace settings'));
    const memberHasJobsCard = await hasVisibleSemanticText(memberPage, 'Instance jobs');
    reportBoolean('non_admin_jobs_card_absent', !memberHasJobsCard);
    assertThat(!memberHasJobsCard, 'non-admin profile rendered instance maintenance controls');

    setStage('verify non-admin direct job endpoint denial');
    const jobsPath = '/api/v1/admin/jobs?limit=50&offset=0';
    const memberRead = await directApi(baseUrl, 'GET', jobsPath, { token: memberAccessToken });
    reportStatus('non_admin_jobs_list', memberRead.status);
    assertThat(memberRead.status === 403, 'non-admin direct jobs listing was not denied');
    const deniedRequestId = crypto.randomUUID();
    const memberWrite = await directApi(baseUrl, 'POST', '/api/v1/admin/jobs', {
      token: memberAccessToken,
      body: { request_id: deniedRequestId, action: 'maintenance' },
    });
    reportStatus('non_admin_jobs_create', memberWrite.status);
    assertThat(memberWrite.status === 403, 'non-admin direct maintenance submission was not denied');
    const deniedBackupRequestId = crypto.randomUUID();
    const memberBackupWrite = await directApi(baseUrl, 'POST', '/api/v1/admin/jobs', {
      token: memberAccessToken,
      body: { request_id: deniedBackupRequestId, action: 'backup' },
    });
    reportStatus('non_admin_backup_create', memberBackupWrite.status);
    assertThat(memberBackupWrite.status === 403, 'non-admin direct backup submission was not denied');

    setStage('load administrator maintenance panel');
    const initialStart = adminRequestSequence();
    await click(adminPage, 'Settings');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Workspace settings'));
    await scrollUntilVisibleSemanticText(adminPage, 'Instance jobs');
    const backupRequirements = await pageVisibleText(adminPage);
    assertThat(backupRequirements.includes('ATERMIUS_BACKUP_ARCHIVE_DIR') &&
        backupRequirements.includes('ATERMIUS_BACKUP_KEY_FILE') &&
        backupRequirements.includes('No archive or key paths are sent by this client.'),
      'administrator backup configuration requirements were missing or unsafe');
    reportBoolean('backup_configuration_requirements_visible', true);
    const loadJobs = adminPage.getByRole('button', { name: 'Load instance jobs', exact: true });
    if (await loadJobs.count() > 0) await loadJobs.first().click();
    setStage('validate administrator jobs list response');
    const initialListEvent = await waitForEvent(adminEvents, adminJobsEvent(adminEvents, 'GET', initialStart));
    const initialListPayload = await initialListEvent.payloadPromise;
    reportStatus('admin_jobs_initial_list', initialListEvent.status);
    assertThat(initialListEvent.hasBearer && initialListEvent.pathname === '/api/v1/admin/jobs' &&
        initialListEvent.query.limit === '50' && initialListEvent.query.offset === '0' &&
        initialListEvent.status === 200,
      'admin maintenance list was not an authenticated first-page request');
    validateJobsPage(initialListPayload, 0);
    reportBoolean('admin_jobs_initial_page_shape_valid', true);

    setStage('submit one maintenance job from administrator UI');
    const postStart = adminRequestSequence();
    await click(adminPage, 'Run maintenance now');
    setStage('validate maintenance job submission response');
    const postEvent = await waitForEvent(adminEvents, adminJobsEvent(adminEvents, 'POST', postStart));
    const postPayload = await postEvent.payloadPromise;
    reportStatus('admin_jobs_create', postEvent.status);
    assertThat(postEvent.hasBearer && postEvent.pathname === '/api/v1/admin/jobs' &&
        exactKeys(postEvent.body, ['request_id', 'action']) &&
        UUID_PATTERN.test(postEvent.body.request_id) && postEvent.body.action === 'maintenance',
      'UI maintenance submission body did not match the strict request contract');
    assertThat(postEvent.status === 202 && exactKeys(postPayload, ['job']),
      'admin maintenance submission did not return the accepted job envelope');
    const acceptedJob = validateJob(postPayload.job);
    assertThat(acceptedJob.request_id === postEvent.body.request_id,
      'accepted job did not preserve the idempotency request ID');
    const jobId = acceptedJob.job_id;
    reportBoolean('maintenance_submission_contract_valid', true);

    const uiPosts = adminEvents.filter((event) => event.route === 'admin-jobs' && event.method === 'POST');
    assertThat(uiPosts.length === 1, 'administrator UI submitted more than one maintenance job');
    reportBoolean('exactly_one_job_submission', true);

    setStage('poll durable job state through administrator panel refresh');
    let currentPage;
    let currentJob;
    let listEvent = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-jobs' && event.method === 'GET' &&
        event.requestSequence > postEvent.requestSequence,
      30000);
    const pollingDeadline = Date.now() + 60000;
    while (Date.now() < pollingDeadline) {
      assertThat(listEvent.status === 200 && listEvent.hasBearer,
        'admin maintenance polling request was not an authenticated success');
      currentPage = await listEvent.payloadPromise;
      const rows = validateJobsPage(currentPage, 1);
      currentJob = rows.find((job) => job.job_id === jobId);
      assertThat(currentJob, 'durable maintenance job was absent from refreshed page');
      if (['succeeded', 'failed', 'interrupted'].includes(currentJob.status)) break;
      const refreshStart = adminRequestSequence();
      await click(adminPage, 'Refresh instance jobs');
      listEvent = await waitForEvent(adminEvents, adminJobsEvent(adminEvents, 'GET', refreshStart), 30000);
    }
    assertThat(currentJob && currentJob.status === 'succeeded' &&
        currentJob.result_code === 'completed' && currentJob.started_at && currentJob.finished_at,
      'maintenance job did not reach a successful durable terminal state');
    reportBoolean('durable_terminal_state_observed', true);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Maintenance · succeeded'), 15000);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Result completed'), 15000);
    reportBoolean('terminal_state_rendered_in_admin_panel', true);

    setStage('confirm persisted job row through authenticated API refresh');
    const persisted = await directApi(baseUrl, 'GET', jobsPath, { token: adminAccessToken });
    reportStatus('admin_jobs_persisted_read', persisted.status);
    assertThat(persisted.status === 200, 'administrator could not re-read the durable job row');
    const persistedRows = validateJobsPage(persisted.body, 1);
    const persistedJob = persistedRows.find((job) => job.job_id === jobId);
    assertThat(persistedJob && persistedJob.status === 'succeeded' &&
        persistedJob.result_code === 'completed' && persistedJob.request_id === postEvent.body.request_id,
      'follow-up API read did not preserve the successful terminal job state');
    reportBoolean('terminal_job_survived_followup_read', true);

    setStage('acquire disposable maintenance lock for real failure coverage');
    const maintenanceFailureLock = await armMaintenanceLockFailure(dataDir, tempRoot);
    assertThat(fs.existsSync(maintenanceFailureLock.readyPath) &&
        maintenanceFailureLock.process.exitCode === null &&
        maintenanceFailureLock.process.signalCode === null,
      'maintenance lock helper did not hold its lock after readiness');
    reportBoolean('maintenance_failure_lock_held_before_settings_submit', true);

    let failedMaintenanceAccepted;
    let failedMaintenanceJob;
    let failedMaintenanceTerminalObserved = false;
    try {
      const [instanceBeforeMaintenanceFailure, profileBeforeMaintenanceFailure] = await Promise.all([
        directApi(baseUrl, 'GET', '/api/v1/instance'),
        directApi(baseUrl, 'GET', '/api/v1/me', { token: adminAccessToken }),
      ]);
      assertThat(instanceBeforeMaintenanceFailure.status === 200 &&
          typeof instanceBeforeMaintenanceFailure.body?.generation === 'string' &&
          profileBeforeMaintenanceFailure.status === 200 &&
          profileBeforeMaintenanceFailure.body?.account_id === admin.accountId &&
          profileBeforeMaintenanceFailure.body?.device_id === admin.deviceId,
        'live instance or administrator session was unavailable before maintenance failure');
      const businessDigestBeforeMaintenanceFailure = readBusinessDatabaseDigest(databasePath);

      setStage('submit maintenance from Settings while fixture lock is held');
      const failedMaintenancePostStart = adminRequestSequence();
      await click(adminPage, 'Run maintenance now');
      const failedMaintenancePostEvent = await waitForEvent(
        adminEvents,
        adminJobsEvent(adminEvents, 'POST', failedMaintenancePostStart),
      );
      const failedMaintenancePostPayload = await failedMaintenancePostEvent.payloadPromise;
      reportStatus('admin_maintenance_failure_job_create', failedMaintenancePostEvent.status);
      const failedMaintenanceContract = {
        bearer: failedMaintenancePostEvent.hasBearer,
        path: failedMaintenancePostEvent.pathname === '/api/v1/admin/jobs',
        bodyKeys: failedMaintenancePostEvent.body &&
          Object.keys(failedMaintenancePostEvent.body).sort(),
        requestIdValid: UUID_PATTERN.test(failedMaintenancePostEvent.body?.request_id || ''),
        action: failedMaintenancePostEvent.body?.action === 'maintenance',
        json: failedMaintenancePostEvent.jsonContentType,
        status: failedMaintenancePostEvent.status,
        payloadKeys: failedMaintenancePostPayload && Object.keys(failedMaintenancePostPayload).sort(),
        jobObject: Boolean(failedMaintenancePostPayload?.job &&
          typeof failedMaintenancePostPayload.job === 'object'),
      };
      console.log(`diagnostic: maintenance_failure_submission_shape=${JSON.stringify(failedMaintenanceContract)}`);
      assertThat(failedMaintenancePostEvent.hasBearer &&
          failedMaintenancePostEvent.pathname === '/api/v1/admin/jobs' &&
          exactKeys(failedMaintenancePostEvent.body, ['request_id', 'action']) &&
          UUID_PATTERN.test(failedMaintenancePostEvent.body.request_id) &&
          failedMaintenancePostEvent.body.action === 'maintenance' &&
          failedMaintenancePostEvent.status === 202 &&
          exactKeys(failedMaintenancePostPayload, ['job']),
        'failed-maintenance UI submission did not match the accepted request contract');
      failedMaintenanceAccepted = validateJob(failedMaintenancePostPayload.job);
      assertThat(failedMaintenanceAccepted.action === 'maintenance' &&
          failedMaintenanceAccepted.request_id === failedMaintenancePostEvent.body.request_id &&
          ['queued', 'running', 'failed'].includes(failedMaintenanceAccepted.status),
        'accepted failure-test maintenance job lost its action or request ID');
      const uiPostsAfterFailedMaintenance = adminEvents.filter((event) =>
        event.route === 'admin-jobs' && event.method === 'POST');
      assertThat(uiPostsAfterFailedMaintenance.length === 2,
        'administrator UI submitted an unexpected number of maintenance jobs');
      reportBoolean('maintenance_failure_submission_contract_valid', true);

      setStage('poll Settings until the durable maintenance failure appears');
      let failureListEvent = await waitForEvent(
        adminEvents,
        (event) => event.route === 'admin-jobs' && event.method === 'GET' &&
          event.requestSequence > failedMaintenancePostEvent.requestSequence,
        30000,
      );
      const failureDeadline = Date.now() + 45000;
      let refreshedFailedMaintenance;
      while (Date.now() < failureDeadline) {
        assertThat(failureListEvent.status === 200 && failureListEvent.hasBearer,
          'maintenance failure polling request was not authenticated and successful');
        const rows = validateJobsPage(await failureListEvent.payloadPromise, 2);
        refreshedFailedMaintenance = rows.find((job) =>
          job.job_id === failedMaintenanceAccepted.job_id);
        assertThat(refreshedFailedMaintenance,
          'failed maintenance job was absent from the refreshed Settings job list');
        if (['failed', 'succeeded', 'interrupted'].includes(refreshedFailedMaintenance.status)) break;
        const refreshStart = adminRequestSequence();
        await click(adminPage, 'Refresh instance jobs');
        failureListEvent = await waitForEvent(
          adminEvents,
          adminJobsEvent(adminEvents, 'GET', refreshStart),
          30000,
        );
      }
      failedMaintenanceJob = refreshedFailedMaintenance;
      failedMaintenanceTerminalObserved = Boolean(failedMaintenanceJob &&
        ['failed', 'succeeded', 'interrupted'].includes(failedMaintenanceJob.status));
      assertThat(failedMaintenanceJob && failedMaintenanceJob.action === 'maintenance' &&
          failedMaintenanceJob.status === 'failed' &&
          failedMaintenanceJob.result_code === 'maintenance_failed' &&
          failedMaintenanceJob.request_id === failedMaintenancePostEvent.body.request_id &&
          failedMaintenanceJob.started_at !== null && failedMaintenanceJob.finished_at !== null,
        'real maintenance lock contention did not persist the expected failed terminal DTO');
      reportBoolean('durable_maintenance_failed_terminal_state_observed', true);

      await waitFor(() => hasVisibleSemanticText(adminPage, 'Maintenance · failed'));
      await waitFor(() => hasVisibleSemanticText(
        adminPage,
        'Maintenance failed; check server health before retrying',
      ));
      const failedMaintenanceVisibleText = await pageVisibleText(adminPage);
      assertNoLeaks(failedMaintenanceVisibleText);
      assertThat(!failedMaintenanceVisibleText.includes('maintenance_failed') &&
          !failedMaintenanceVisibleText.includes('MAINTENANCE_ALREADY_RUNNING') &&
          !failedMaintenanceVisibleText.includes(maintenanceFailureLock.lockPath),
        'Settings exposed a raw maintenance failure code, lock conflict, or path');
      reportBoolean('maintenance_failed_job_renders_safe_guidance', true);

      setStage('confirm failed maintenance DTO and unchanged live business state');
      const persistedMaintenanceFailure = await directApi(baseUrl, 'GET', jobsPath, {
        token: adminAccessToken,
      });
      assertThat(persistedMaintenanceFailure.status === 200,
        'administrator could not re-read the failed maintenance DTO');
      const persistedMaintenanceRows = validateJobsPage(persistedMaintenanceFailure.body, 2);
      const persistedFailedMaintenance = persistedMaintenanceRows.find((job) =>
        job.job_id === failedMaintenanceAccepted.job_id);
      const jobDtoFingerprint = (job) => JSON.stringify([
        job.job_id, job.request_id, job.action, job.archive_id, job.archive_source,
        job.status, job.requested_at, job.started_at, job.finished_at, job.result_code,
      ]);
      assertThat(persistedFailedMaintenance &&
          jobDtoFingerprint(persistedFailedMaintenance) === jobDtoFingerprint(failedMaintenanceJob),
        'follow-up API DTO did not match the failed job rendered by Settings');
      reportBoolean('maintenance_failure_api_settings_job_fingerprint_matches', true);

      const [instanceAfterMaintenanceFailure, profileAfterMaintenanceFailure] = await Promise.all([
        directApi(baseUrl, 'GET', '/api/v1/instance'),
        directApi(baseUrl, 'GET', '/api/v1/me', { token: adminAccessToken }),
      ]);
      const businessDigestAfterMaintenanceFailure = readBusinessDatabaseDigest(databasePath);
      assertThat(JSON.stringify(businessDigestAfterMaintenanceFailure) ===
          JSON.stringify(businessDigestBeforeMaintenanceFailure) &&
          instanceAfterMaintenanceFailure.status === 200 &&
          instanceAfterMaintenanceFailure.body?.generation ===
            instanceBeforeMaintenanceFailure.body.generation &&
          profileAfterMaintenanceFailure.status === 200 &&
          profileAfterMaintenanceFailure.body?.account_id === admin.accountId &&
          profileAfterMaintenanceFailure.body?.device_id === admin.deviceId,
        'failed maintenance changed business rows, generation, or administrator session');
      reportBoolean('maintenance_failed_preserved_business_state_generation_and_session', true);
    } finally {
      if (maintenanceLockProcess) {
        if (failedMaintenanceAccepted && !failedMaintenanceTerminalObserved) {
          try {
            failedMaintenanceJob = await waitForAdminJobTerminal(
              baseUrl,
              adminAccessToken,
              failedMaintenanceAccepted.job_id,
              10000,
            );
            failedMaintenanceTerminalObserved = true;
          } catch (_) {
            try {
              await stopServerGroup(serverProcess);
            } catch (_) {
              cleanupFailed = true;
              throw new Error('isolated server could not be stopped while holding the maintenance lock');
            }
            serverProcess = undefined;
          }
        }
        await releaseMaintenanceLockHelper();
      }
    }
    reportBoolean('maintenance_failure_lock_helper_released', !maintenanceLockProcess);

    let interruptedMaintenanceJob;
    let interruptedMaintenanceBreakpoint;
    try {
      setStage('arm real maintenance worker interruption after durable start');
      interruptedMaintenanceBreakpoint = await armAdminJobInterruptedBreakpoint(
        tempRoot,
        'maintenance',
      );
      interruptedAdminJobBreakpoint = interruptedMaintenanceBreakpoint;

      const [instanceBeforeInterruption, profileBeforeInterruption] = await Promise.all([
        directApi(baseUrl, 'GET', '/api/v1/instance'),
        directApi(baseUrl, 'GET', '/api/v1/me', { token: adminAccessToken }),
      ]);
      assertThat(instanceBeforeInterruption.status === 200 &&
          typeof instanceBeforeInterruption.body?.generation === 'string' &&
          profileBeforeInterruption.status === 200 &&
          profileBeforeInterruption.body?.account_id === admin.accountId &&
          profileBeforeInterruption.body?.device_id === admin.deviceId,
        'live instance or administrator session was unavailable before maintenance interruption');
      const businessDigestBeforeInterruption = readBusinessDatabaseDigest(databasePath);

      setStage('submit maintenance job for actual process interruption');
      const interruptedPostStart = adminRequestSequence();
      await click(adminPage, 'Run maintenance now');
      const interruptedPostEvent = await waitForEvent(
        adminEvents,
        adminJobsEvent(adminEvents, 'POST', interruptedPostStart),
      );
      const interruptedPostPayload = await interruptedPostEvent.payloadPromise;
      reportStatus('admin_maintenance_interrupted_job_create', interruptedPostEvent.status);
      assertThat(interruptedPostEvent.hasBearer &&
          interruptedPostEvent.pathname === '/api/v1/admin/jobs' &&
          exactKeys(interruptedPostEvent.body, ['request_id', 'action']) &&
          UUID_PATTERN.test(interruptedPostEvent.body.request_id) &&
          interruptedPostEvent.body.action === 'maintenance' &&
          interruptedPostEvent.status === 202 &&
          exactKeys(interruptedPostPayload, ['job']),
        'interrupted-maintenance UI submission did not match the accepted request contract');
      const acceptedInterruptedMaintenance = validateJob(interruptedPostPayload.job);
      assertThat(acceptedInterruptedMaintenance.action === 'maintenance' &&
          acceptedInterruptedMaintenance.request_id === interruptedPostEvent.body.request_id &&
          ['queued', 'running'].includes(acceptedInterruptedMaintenance.status),
        'accepted interrupted-maintenance job lost its action or request ID');

      setStage('wait until the actual worker is paused after its running transaction');
      await waitForFile(interruptedMaintenanceBreakpoint.hitPath, 30000,
        'maintenance worker did not reach the post-start interruption point');
      const runningBeforeRestart = readAdminJobBeforeRestart(
        databasePath,
        acceptedInterruptedMaintenance.job_id,
      );
      const runningStartedAt = runningBeforeRestart?.started_at;
      const runningStartedAtValid = typeof runningStartedAt === 'string' &&
        /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(runningStartedAt) &&
        !Number.isNaN(Date.parse(runningStartedAt));
      assertThat(runningBeforeRestart &&
          runningBeforeRestart.request_id === interruptedPostEvent.body.request_id &&
          runningBeforeRestart.action === 'maintenance' &&
          runningBeforeRestart.status === 'running' &&
          runningStartedAtValid &&
          runningBeforeRestart.finished_at === null &&
          runningBeforeRestart.result_code === null,
        'read-only database snapshot did not prove the real worker was durably running before interruption');
      reportBoolean('maintenance_worker_paused_after_durable_running_commit', true);

      setStage('SIGKILL the paused server and restart for startup recovery');
      await killPausedAdminJobWorker(serverProcess, interruptedMaintenanceBreakpoint);
      setStage('hold the automatic startup maintenance pass while checking recovery');
      await armMaintenanceLockFailure(dataDir, tempRoot);
      reportBoolean('startup_maintenance_lock_held_during_recovery_assertions', true);
      const restartedServer = spawn(SERVER_BINARY, ['serve'], {
        cwd: ROOT,
        env: serverEnv,
        detached: true,
        stdio: 'ignore',
      });
      serverProcess = restartedServer;
      await waitForServer(baseUrl, restartedServer);
      reportBoolean('server_restarted_and_startup_recovery_completed', true);

      const recoveredPage = await directApi(baseUrl, 'GET', jobsPath, {
        token: adminAccessToken,
      });
      reportStatus('interrupted_maintenance_recovery_read', recoveredPage.status);
      assertThat(recoveredPage.status === 200,
        'administrator could not read the recovered maintenance job after restart');
      const recoveredRows = validateJobsPage(recoveredPage.body, 3);
      interruptedMaintenanceJob = recoveredRows.find((job) =>
        job.job_id === acceptedInterruptedMaintenance.job_id);
      assertThat(interruptedMaintenanceJob &&
          interruptedMaintenanceJob.action === 'maintenance' &&
          interruptedMaintenanceJob.request_id === interruptedPostEvent.body.request_id &&
          interruptedMaintenanceJob.status === 'interrupted' &&
          interruptedMaintenanceJob.result_code === 'interrupted' &&
          interruptedMaintenanceJob.started_at !== null &&
          interruptedMaintenanceJob.finished_at !== null,
        'startup recovery did not persist the expected interrupted maintenance DTO');
      reportBoolean('durable_maintenance_interrupted_state_observed', true);

      setStage('refresh Settings and compare interrupted job DTO fingerprint');
      const interruptedRefreshStart = adminRequestSequence();
      await click(adminPage, 'Refresh instance jobs');
      const interruptedRefreshEvent = await waitForEvent(
        adminEvents,
        adminJobsEvent(adminEvents, 'GET', interruptedRefreshStart),
      );
      const interruptedSettingsPage = await interruptedRefreshEvent.payloadPromise;
      assertThat(interruptedRefreshEvent.hasBearer && interruptedRefreshEvent.status === 200,
        'Settings did not reload interrupted jobs through the authenticated API');
      const interruptedSettingsRows = validateJobsPage(interruptedSettingsPage, 3);
      const interruptedSettingsJob = interruptedSettingsRows.find((job) =>
        job.job_id === interruptedMaintenanceJob.job_id);
      const interruptedDtoFingerprint = (job) => JSON.stringify([
        job.job_id, job.request_id, job.action, job.archive_id, job.archive_source,
        job.status, job.requested_at, job.started_at, job.finished_at, job.result_code,
      ]);
      assertThat(interruptedSettingsJob &&
          interruptedDtoFingerprint(interruptedSettingsJob) ===
            interruptedDtoFingerprint(interruptedMaintenanceJob),
        'Settings interrupted-job DTO did not match the recovered API row');
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Maintenance · interrupted'));
      await waitFor(() => hasVisibleSemanticText(
        adminPage,
        'Maintenance was interrupted; refresh the job list before retrying',
      ));
      const interruptedVisibleText = await pageVisibleText(adminPage);
      assertNoLeaks(interruptedVisibleText);
      assertThat(!interruptedVisibleText.includes('Result interrupted') &&
          !interruptedVisibleText.includes(interruptedMaintenanceBreakpoint.releasePath) &&
          !interruptedVisibleText.includes(interruptedMaintenanceBreakpoint.hitPath),
        'Settings exposed a raw interrupted result code or debugger marker path');
      reportBoolean('maintenance_interrupted_job_renders_safe_guidance', true);
      reportBoolean('maintenance_interrupted_api_settings_fingerprint_matches', true);

      setStage('verify restart recovery audit HMAC and unchanged live state');
      const recoveredAudit = await directApi(baseUrl, 'GET', '/api/v1/admin/audit?limit=200', {
        token: adminAccessToken,
      });
      assertThat(recoveredAudit.status === 200,
        'administrator could not read audit events for interrupted maintenance recovery');
      const interruptedAuditEvents = validateAuditPage(recoveredAudit.body).filter((event) =>
        event.resource_type === 'admin_job' &&
        ['admin.maintenance_requested', 'admin.maintenance_started',
          'admin.maintenance_interrupted'].includes(event.action) &&
        event.actor_user_id === admin.accountId &&
        event.actor_device_id === admin.deviceId);
      const interruptedAuditGroups = new Map();
      for (const event of interruptedAuditEvents) {
        if (!interruptedAuditGroups.has(event.resource_id)) {
          interruptedAuditGroups.set(event.resource_id, []);
        }
        interruptedAuditGroups.get(event.resource_id).push(event);
      }
      const interruptedLifecycle = [...interruptedAuditGroups.values()].find((events) =>
        events.length === 3 && [...events]
          .sort((left, right) => BigInt(left.event_id) < BigInt(right.event_id) ? -1 : 1)
          .map((event) => event.action).join(',') ===
          'admin.maintenance_requested,admin.maintenance_started,admin.maintenance_interrupted')
        ?.sort((left, right) => BigInt(left.event_id) < BigInt(right.event_id) ? -1 : 1) || [];
      assertThat(interruptedAuditGroups.size === 3 && interruptedLifecycle.length === 3 &&
          interruptedLifecycle.map((event) => event.action).join(',') ===
            'admin.maintenance_requested,admin.maintenance_started,admin.maintenance_interrupted' &&
          interruptedLifecycle.every((event) => event.scope === 'instance' &&
            event.source === 'api' &&
            (event.action === 'admin.maintenance_interrupted'
              ? event.result === 'failure'
              : event.result === 'success')) &&
          typeof interruptedLifecycle[0]?.resource_id === 'string' &&
          /^[0-9a-f]{64}$/.test(interruptedLifecycle[0].resource_id) &&
          interruptedLifecycle[0].resource_id !== interruptedMaintenanceJob.job_id,
        'interrupted maintenance request/start/recovery audit lifecycle or HMAC reference was invalid');
      reportBoolean('maintenance_interrupted_audit_lifecycle_and_hmac_valid', true);

      const [instanceAfterInterruption, profileAfterInterruption] = await Promise.all([
        directApi(baseUrl, 'GET', '/api/v1/instance'),
        directApi(baseUrl, 'GET', '/api/v1/me', { token: adminAccessToken }),
      ]);
      const businessDigestAfterInterruption = readBusinessDatabaseDigest(databasePath);
      const businessStateUnchanged = JSON.stringify(businessDigestAfterInterruption) ===
        JSON.stringify(businessDigestBeforeInterruption);
      const instanceGenerationUnchanged = instanceAfterInterruption.status === 200 &&
        instanceAfterInterruption.body?.generation ===
          instanceBeforeInterruption.body.generation;
      const adminSessionStillValid = profileAfterInterruption.status === 200 &&
        profileAfterInterruption.body?.account_id === admin.accountId &&
        profileAfterInterruption.body?.device_id === admin.deviceId;
      reportBoolean('maintenance_interruption_business_state_unchanged', businessStateUnchanged);
      reportBoolean('maintenance_interruption_generation_unchanged', instanceGenerationUnchanged);
      reportBoolean('maintenance_interruption_admin_session_valid', adminSessionStillValid);
      assertThat(businessStateUnchanged && instanceGenerationUnchanged && adminSessionStillValid,
        'interrupted maintenance changed business rows, generation, or administrator session');
      await releaseMaintenanceLockHelper();
      reportBoolean('startup_maintenance_lock_helper_released', !maintenanceLockProcess);
      reportBoolean('maintenance_interrupted_preserved_business_state_generation_and_session', true);
    } finally {
      if (interruptedAdminJobBreakpoint && serverProcess) {
        await killPausedAdminJobWorker(serverProcess, interruptedAdminJobBreakpoint);
      }
    }

    let interruptedBackupJob;
    let interruptedBackupBreakpoint;
    try {
      setStage('arm real backup worker interruption after durable start');
      interruptedBackupBreakpoint = await armAdminJobInterruptedBreakpoint(tempRoot, 'backup');
      interruptedAdminJobBreakpoint = interruptedBackupBreakpoint;

      const [instanceBeforeBackupInterruption, profileBeforeBackupInterruption] = await Promise.all([
        directApi(baseUrl, 'GET', '/api/v1/instance'),
        directApi(baseUrl, 'GET', '/api/v1/me', { token: adminAccessToken }),
      ]);
      assertThat(instanceBeforeBackupInterruption.status === 200 &&
          typeof instanceBeforeBackupInterruption.body?.generation === 'string' &&
          profileBeforeBackupInterruption.status === 200 &&
          profileBeforeBackupInterruption.body?.account_id === admin.accountId &&
          profileBeforeBackupInterruption.body?.device_id === admin.deviceId,
        'live instance or administrator session was unavailable before backup interruption');
      const businessDigestBeforeBackupInterruption = readBusinessDatabaseDigest(databasePath);
      const archiveFilesBeforeBackupInterruption = fs.readdirSync(backupArchiveDir).sort();

      setStage('submit backup job for actual process interruption');
      const interruptedBackupPostStart = adminRequestSequence();
      await click(adminPage, 'Run encrypted backup');
      const interruptedBackupPostEvent = await waitForEvent(
        adminEvents,
        adminJobsEvent(adminEvents, 'POST', interruptedBackupPostStart),
      );
      const interruptedBackupPostPayload = await interruptedBackupPostEvent.payloadPromise;
      reportStatus('admin_backup_interrupted_job_create', interruptedBackupPostEvent.status);
      assertThat(interruptedBackupPostEvent.hasBearer &&
          interruptedBackupPostEvent.pathname === '/api/v1/admin/jobs' &&
          exactKeys(interruptedBackupPostEvent.body, ['request_id', 'action']) &&
          UUID_PATTERN.test(interruptedBackupPostEvent.body.request_id) &&
          interruptedBackupPostEvent.body.action === 'backup' &&
          interruptedBackupPostEvent.status === 202 &&
          exactKeys(interruptedBackupPostPayload, ['job']),
        'interrupted-backup UI submission did not match the accepted request contract');
      const acceptedInterruptedBackup = validateJob(interruptedBackupPostPayload.job);
      assertThat(acceptedInterruptedBackup.action === 'backup' &&
          acceptedInterruptedBackup.request_id === interruptedBackupPostEvent.body.request_id &&
          ['queued', 'running'].includes(acceptedInterruptedBackup.status),
        'accepted interrupted-backup job lost its action or request ID');
      const uiPostsAfterInterruptedBackup = adminEvents.filter((event) =>
        event.route === 'admin-jobs' && event.method === 'POST');
      assertThat(uiPostsAfterInterruptedBackup.length === 4,
        'administrator UI submitted an unexpected number of jobs before backup interruption');

      setStage('wait until the actual backup worker is paused after its running transaction');
      await waitForFile(interruptedBackupBreakpoint.hitPath, 30000,
        'backup worker did not reach the post-start interruption point');
      const backupRunningBeforeRestart = readAdminJobBeforeRestart(
        databasePath,
        acceptedInterruptedBackup.job_id,
      );
      const backupRunningStartedAt = backupRunningBeforeRestart?.started_at;
      const backupRunningStartedAtValid = typeof backupRunningStartedAt === 'string' &&
        /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(backupRunningStartedAt) &&
        !Number.isNaN(Date.parse(backupRunningStartedAt));
      assertThat(backupRunningBeforeRestart &&
          backupRunningBeforeRestart.request_id === interruptedBackupPostEvent.body.request_id &&
          backupRunningBeforeRestart.action === 'backup' &&
          backupRunningBeforeRestart.status === 'running' &&
          backupRunningStartedAtValid &&
          backupRunningBeforeRestart.finished_at === null &&
          backupRunningBeforeRestart.result_code === null,
        'read-only database snapshot did not prove the real backup worker was durably running');
      reportBoolean('backup_worker_paused_after_durable_running_commit', true);
      const businessDigestAtBackupRunning = readBusinessDatabaseDigest(databasePath);
      const tablesChangedBeforeBackupWorkerStart = Object.keys({
        ...businessDigestBeforeBackupInterruption.table_hashes,
        ...businessDigestAtBackupRunning.table_hashes,
      }).filter((table) => businessDigestBeforeBackupInterruption.table_hashes[table] !==
        businessDigestAtBackupRunning.table_hashes[table]).sort();
      console.log(`diagnostic: backup_request_to_running_changed_business_tables=${JSON.stringify(tablesChangedBeforeBackupWorkerStart)}`);
      assertThat(tablesChangedBeforeBackupWorkerStart.length === 0,
        'backup request changed durable account/Vault business tables before worker execution');

      setStage('SIGKILL the paused backup server and restart for startup recovery');
      await killPausedAdminJobWorker(serverProcess, interruptedBackupBreakpoint);
      setStage('hold automatic startup maintenance while checking backup recovery');
      await armMaintenanceLockFailure(dataDir, tempRoot);
      reportBoolean('startup_maintenance_lock_held_during_backup_recovery_assertions', true);
      const restartedForBackupRecovery = spawn(SERVER_BINARY, ['serve'], {
        cwd: ROOT,
        env: serverEnv,
        detached: true,
        stdio: 'ignore',
      });
      serverProcess = restartedForBackupRecovery;
      await waitForServer(baseUrl, restartedForBackupRecovery);
      reportBoolean('server_restarted_for_backup_startup_recovery', true);

      const recoveredBackupPage = await directApi(baseUrl, 'GET', jobsPath, {
        token: adminAccessToken,
      });
      reportStatus('interrupted_backup_recovery_read', recoveredBackupPage.status);
      assertThat(recoveredBackupPage.status === 200,
        'administrator could not read recovered backup job after restart');
      const recoveredBackupRows = validateJobsPage(recoveredBackupPage.body, 4);
      interruptedBackupJob = recoveredBackupRows.find((job) =>
        job.job_id === acceptedInterruptedBackup.job_id);
      assertThat(interruptedBackupJob && interruptedBackupJob.action === 'backup' &&
          interruptedBackupJob.request_id === interruptedBackupPostEvent.body.request_id &&
          interruptedBackupJob.status === 'interrupted' &&
          interruptedBackupJob.result_code === 'interrupted' &&
          interruptedBackupJob.started_at !== null &&
          interruptedBackupJob.finished_at !== null,
        'startup recovery did not persist the expected interrupted backup DTO');
      reportBoolean('durable_backup_interrupted_state_observed', true);

      setStage('refresh Settings and compare interrupted backup DTO fingerprint');
      const interruptedBackupRefreshStart = adminRequestSequence();
      await click(adminPage, 'Refresh instance jobs');
      const interruptedBackupRefreshEvent = await waitForEvent(
        adminEvents,
        adminJobsEvent(adminEvents, 'GET', interruptedBackupRefreshStart),
      );
      const interruptedBackupSettingsPage = await interruptedBackupRefreshEvent.payloadPromise;
      assertThat(interruptedBackupRefreshEvent.hasBearer &&
          interruptedBackupRefreshEvent.status === 200,
        'Settings did not reload interrupted backup jobs through the authenticated API');
      const interruptedBackupSettingsRows = validateJobsPage(interruptedBackupSettingsPage, 4);
      const interruptedBackupSettingsJob = interruptedBackupSettingsRows.find((job) =>
        job.job_id === interruptedBackupJob.job_id);
      const interruptedBackupDtoFingerprint = (job) => JSON.stringify([
        job.job_id, job.request_id, job.action, job.archive_id, job.archive_source,
        job.status, job.requested_at, job.started_at, job.finished_at, job.result_code,
      ]);
      assertThat(interruptedBackupSettingsJob &&
          interruptedBackupDtoFingerprint(interruptedBackupSettingsJob) ===
            interruptedBackupDtoFingerprint(interruptedBackupJob),
        'Settings interrupted-backup DTO did not match the recovered API row');
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Encrypted backup · interrupted'));
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Encrypted backup job interrupted'));
      const interruptedBackupVisibleText = await pageVisibleText(adminPage);
      assertNoLeaks(interruptedBackupVisibleText);
      assertThat(!interruptedBackupVisibleText.includes('Result interrupted') &&
          !interruptedBackupVisibleText.includes(interruptedBackupBreakpoint.releasePath) &&
          !interruptedBackupVisibleText.includes(interruptedBackupBreakpoint.hitPath),
        'Settings exposed a raw interrupted backup result code or debugger marker path');
      reportBoolean('backup_interrupted_job_renders_safe_guidance', true);
      reportBoolean('backup_interrupted_api_settings_fingerprint_matches', true);

      setStage('verify backup recovery audit HMAC and unchanged artifact/business state');
      const recoveredBackupAudit = await directApi(baseUrl, 'GET', '/api/v1/admin/audit?limit=200', {
        token: adminAccessToken,
      });
      assertThat(recoveredBackupAudit.status === 200,
        'administrator could not read audit events for interrupted backup recovery');
      const interruptedBackupAuditEvents = validateAuditPage(recoveredBackupAudit.body).filter((event) =>
        event.resource_type === 'admin_job' &&
        ['admin.backup_requested', 'admin.backup_started', 'admin.backup_interrupted'].includes(event.action) &&
        event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId);
      const interruptedBackupAuditGroups = new Map();
      for (const event of interruptedBackupAuditEvents) {
        if (!interruptedBackupAuditGroups.has(event.resource_id)) {
          interruptedBackupAuditGroups.set(event.resource_id, []);
        }
        interruptedBackupAuditGroups.get(event.resource_id).push(event);
      }
      const interruptedBackupLifecycle = [...interruptedBackupAuditGroups.values()].find((events) =>
        events.length === 3 && [...events]
          .sort((left, right) => BigInt(left.event_id) < BigInt(right.event_id) ? -1 : 1)
          .map((event) => event.action).join(',') ===
          'admin.backup_requested,admin.backup_started,admin.backup_interrupted')
        ?.sort((left, right) => BigInt(left.event_id) < BigInt(right.event_id) ? -1 : 1) || [];
      assertThat(interruptedBackupAuditGroups.size === 1 &&
          interruptedBackupLifecycle.length === 3 &&
          interruptedBackupLifecycle.every((event) => event.scope === 'instance' &&
            event.source === 'api' &&
            (event.action === 'admin.backup_interrupted'
              ? event.result === 'failure'
              : event.result === 'success')) &&
          typeof interruptedBackupLifecycle[0]?.resource_id === 'string' &&
          /^[0-9a-f]{64}$/.test(interruptedBackupLifecycle[0].resource_id) &&
          interruptedBackupLifecycle[0].resource_id !== interruptedBackupJob.job_id,
        'interrupted backup request/start/recovery audit lifecycle or HMAC reference was invalid');
      reportBoolean('backup_interrupted_audit_lifecycle_and_hmac_valid', true);

      const [instanceAfterBackupInterruption, profileAfterBackupInterruption] = await Promise.all([
        directApi(baseUrl, 'GET', '/api/v1/instance'),
        directApi(baseUrl, 'GET', '/api/v1/me', { token: adminAccessToken }),
      ]);
      const businessDigestAfterBackupInterruption = readBusinessDatabaseDigest(databasePath);
      const archiveFilesAfterBackupInterruption = fs.readdirSync(backupArchiveDir).sort();
      const businessStateUnchangedAfterBackupInterruption =
        JSON.stringify(businessDigestAfterBackupInterruption) ===
          JSON.stringify(businessDigestAtBackupRunning);
      const tablesChangedDuringBackupRecovery = Object.keys({
        ...businessDigestAtBackupRunning.table_hashes,
        ...businessDigestAfterBackupInterruption.table_hashes,
      }).filter((table) => businessDigestAtBackupRunning.table_hashes[table] !==
        businessDigestAfterBackupInterruption.table_hashes[table]).sort();
      console.log(`diagnostic: backup_running_to_recovery_changed_business_tables=${JSON.stringify(tablesChangedDuringBackupRecovery)}`);
      const archivesUnchangedAfterBackupInterruption =
        JSON.stringify(archiveFilesAfterBackupInterruption) ===
          JSON.stringify(archiveFilesBeforeBackupInterruption);
      const generationUnchangedAfterBackupInterruption =
        instanceAfterBackupInterruption.status === 200 &&
        instanceAfterBackupInterruption.body?.generation ===
          instanceBeforeBackupInterruption.body.generation;
      const sessionValidAfterBackupInterruption =
        profileAfterBackupInterruption.status === 200 &&
        profileAfterBackupInterruption.body?.account_id === admin.accountId &&
        profileAfterBackupInterruption.body?.device_id === admin.deviceId;
      reportBoolean('backup_interruption_business_state_unchanged',
        businessStateUnchangedAfterBackupInterruption);
      reportBoolean('backup_interruption_archives_unchanged', archivesUnchangedAfterBackupInterruption);
      reportBoolean('backup_interruption_generation_unchanged',
        generationUnchangedAfterBackupInterruption);
      reportBoolean('backup_interruption_admin_session_valid', sessionValidAfterBackupInterruption);
      assertThat(businessStateUnchangedAfterBackupInterruption &&
          archivesUnchangedAfterBackupInterruption &&
          generationUnchangedAfterBackupInterruption && sessionValidAfterBackupInterruption,
        'interrupted backup changed business rows, archive files, generation, or administrator session');
      await releaseMaintenanceLockHelper();
      reportBoolean('startup_maintenance_lock_helper_released_after_backup', !maintenanceLockProcess);
    } finally {
      if (interruptedAdminJobBreakpoint && serverProcess) {
        await killPausedAdminJobWorker(serverProcess, interruptedAdminJobBreakpoint);
      }
    }

    setStage('submit one encrypted backup job from administrator UI');
    const backupPostStart = adminRequestSequence();
    await click(adminPage, 'Run encrypted backup');
    const backupPostEvent = await waitForEvent(
      adminEvents,
      adminJobsEvent(adminEvents, 'POST', backupPostStart),
    );
    const backupPostPayload = await backupPostEvent.payloadPromise;
    reportStatus('admin_backup_job_create', backupPostEvent.status);
    assertThat(backupPostEvent.hasBearer &&
        backupPostEvent.pathname === '/api/v1/admin/jobs' &&
        exactKeys(backupPostEvent.body, ['request_id', 'action']) &&
        UUID_PATTERN.test(backupPostEvent.body.request_id) &&
        backupPostEvent.body.action === 'backup',
      'UI backup submission body did not match the strict request contract');
    assertThat(backupPostEvent.status === 202 &&
        exactKeys(backupPostPayload, ['job']),
      'admin backup submission did not return the accepted job envelope');
    const acceptedBackupJob = validateJob(backupPostPayload.job);
    assertThat(acceptedBackupJob.action === 'backup' &&
        acceptedBackupJob.request_id === backupPostEvent.body.request_id,
      'accepted backup job did not preserve action and idempotency request ID');
    reportBoolean('backup_submission_contract_valid', true);

    const uiPostsAfterBackup = adminEvents.filter((event) =>
      event.route === 'admin-jobs' && event.method === 'POST');
    assertThat(uiPostsAfterBackup.length === 5,
      'administrator UI submitted an unexpected number of maintenance and backup jobs');

    setStage('poll durable encrypted backup state through administrator panel');
    let backupListEvent = await waitForEvent(
      adminEvents,
      (event) => event.route === 'admin-jobs' &&
        event.method === 'GET' && event.requestSequence > backupPostEvent.requestSequence,
      30000,
    );
    let currentBackupJob;
    const backupDeadline = Date.now() + 60000;
    while (Date.now() < backupDeadline) {
      assertThat(backupListEvent.status === 200 && backupListEvent.hasBearer,
        'admin backup polling request was not an authenticated success');
      const backupPage = await backupListEvent.payloadPromise;
      const backupRows = validateJobsPage(backupPage, 5, backupListEvent.jsonContentType);
      currentBackupJob = backupRows.find((job) => job.job_id === acceptedBackupJob.job_id);
      assertThat(currentBackupJob && currentBackupJob.action === 'backup',
        'durable encrypted backup job was absent from refreshed page');
      if (['succeeded', 'failed', 'interrupted'].includes(currentBackupJob.status)) break;
      const refreshStart = adminRequestSequence();
      await click(adminPage, 'Refresh instance jobs');
      backupListEvent = await waitForEvent(
        adminEvents,
        adminJobsEvent(adminEvents, 'GET', refreshStart),
        30000,
      );
    }
    assertThat(currentBackupJob && currentBackupJob.status === 'succeeded' &&
        currentBackupJob.result_code === 'completed' &&
        currentBackupJob.started_at && currentBackupJob.finished_at,
      'encrypted backup job did not reach a successful durable terminal state');
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Encrypted backup · succeeded'), 15000);
    await waitFor(() => hasVisibleSemanticText(adminPage, 'Encrypted backup completed on server'), 15000);
    reportBoolean('backup_terminal_state_rendered', true);

    const archiveFiles = fs.readdirSync(backupArchiveDir);
    assertThat(archiveFiles.length === 1 &&
        fs.statSync(path.join(backupArchiveDir, archiveFiles[0])).isFile() &&
        fs.statSync(path.join(backupArchiveDir, archiveFiles[0])).size > 0,
      'successful encrypted backup did not create one nonempty server archive');
    reportBoolean('server_archive_created_in_operator_configured_directory', true);

    const backupArchivePath = path.join(backupArchiveDir, archiveFiles[0]);
    const verification = spawnSync(SERVER_BINARY, [
      'verify-backup', '--archive', backupArchivePath,
      '--key-file', backupKeyFile,
    ], {
      cwd: ROOT,
      env: serverEnv,
      encoding: 'utf8',
      timeout: 60000,
    });
    assertThat(!verification.error && verification.status === 0,
      'server-triggered archive did not pass the independent archive verifier');
    assertThat(!`${verification.stdout}${verification.stderr}`.includes(backupArchiveDir) &&
        !`${verification.stdout}${verification.stderr}`.includes(backupKeyFile),
      'archive verifier output disclosed a configured backup path');
    reportBoolean('server_archive_verifies_without_path_disclosure', true);

    const backupStatus = await directApi(baseUrl, 'GET', '/api/v1/admin/backup-status', {
      token: adminAccessToken,
    });
    reportStatus('admin_backup_status_after_job', backupStatus.status);
    assertThat(backupStatus.status === 200 &&
        exactKeys(backupStatus.body, ['operation', 'last_attempt']) &&
        backupStatus.body.operation === 'backup' &&
        exactKeys(backupStatus.body.last_attempt, [
          'attempted_at', 'result', 'migration_version', 'archive_bytes', 'failure_category',
        ]) &&
        backupStatus.body.last_attempt.result === 'succeeded' &&
        backupStatus.body.last_attempt.migration_version >= 0 &&
        backupStatus.body.last_attempt.archive_bytes === fs.statSync(backupArchivePath).size &&
        backupStatus.body.last_attempt.failure_category === null,
      'backup status did not report safe successful metadata for the generated archive');
    assertThat(!JSON.stringify(backupStatus.body).includes(backupArchiveDir) &&
        !JSON.stringify(backupStatus.body).includes(backupKeyFile),
      'backup status disclosed a configured backup path');
    reportBoolean('admin_backup_status_metadata_valid_and_path_free', true);

    setStage('render server-triggered backup result in status card');
    const backupStatusRefreshStart = adminRequestSequence();
    const statusButton = await hasVisibleSemanticText(adminPage, 'Load backup status')
      ? 'Load backup status'
      : 'Refresh backup status';
    await click(adminPage, statusButton);
    const backupStatusEvent = await waitForEvent(
      adminEvents,
      (event) => event.route === 'backup-status' && event.method === 'GET' &&
        event.requestSequence > backupStatusRefreshStart,
    );
    assertThat(backupStatusEvent.status === 200 && backupStatusEvent.hasBearer,
      'administrator backup status refresh was not authenticated and successful');
    await waitFor(async () => {
      const visible = await pageVisibleText(adminPage);
      return visible.includes('Succeeded') && visible.includes('Archive bytes');
    });
    reportBoolean('server_triggered_backup_result_rendered', true);

    const successfulArchiveDigest = crypto.createHash('sha256')
      .update(fs.readFileSync(backupArchivePath)).digest('hex');
    const instanceBeforeBackupFailure = await directApi(baseUrl, 'GET', '/api/v1/instance');
    assertThat(instanceBeforeBackupFailure.status === 200 &&
        typeof instanceBeforeBackupFailure.body?.generation === 'string',
      'live instance state was unavailable before the failed backup job');
    let failedBackupJob;
    setStage('arm deterministic backup key validation breakpoint');
    const backupFailureBreakpoint = await armManualBackupFailureBreakpoint(tempRoot);
    try {
      setStage('submit a second encrypted backup for failure coverage');
      const failedBackupPostStart = adminRequestSequence();
      await click(adminPage, 'Run encrypted backup');
      const failedBackupPostEvent = await waitForEvent(
        adminEvents,
        adminJobsEvent(adminEvents, 'POST', failedBackupPostStart),
      );
      const failedBackupPostPayload = await failedBackupPostEvent.payloadPromise;
      reportStatus('admin_backup_failure_job_create', failedBackupPostEvent.status);
      assertThat(failedBackupPostEvent.hasBearer &&
          failedBackupPostEvent.pathname === '/api/v1/admin/jobs' &&
          exactKeys(failedBackupPostEvent.body, ['request_id', 'action']) &&
          UUID_PATTERN.test(failedBackupPostEvent.body.request_id) &&
          failedBackupPostEvent.body.action === 'backup' &&
          failedBackupPostEvent.status === 202 &&
          exactKeys(failedBackupPostPayload, ['job']),
        'failed-backup UI submission did not match the accepted request contract');
      failedBackupJob = validateJob(failedBackupPostPayload.job);
      assertThat(failedBackupJob.action === 'backup' &&
          failedBackupJob.request_id === failedBackupPostEvent.body.request_id &&
          failedBackupJob.status === 'queued',
        'accepted failure-test backup did not preserve its request ID or queued state');
      const uiPostsAfterFailedBackup = adminEvents.filter((event) =>
        event.route === 'admin-jobs' && event.method === 'POST');
      assertThat(uiPostsAfterFailedBackup.length === 6,
        'administrator UI submitted an unexpected number of maintenance and backup jobs');

      setStage('hold only the disposable key after worker validation pauses');
      await waitForFile(backupFailureBreakpoint.hitPath, 30000,
        'manual backup worker did not reach configured-key validation');
      assertThat(fs.existsSync(backupKeyFile) &&
          !fs.existsSync(backupKeyQuarantinePath),
        'disposable key was not in its original state before the failure injection');
      fs.renameSync(backupKeyFile, backupKeyQuarantinePath);
      backupKeyQuarantined = true;
      const heldKeyMetadata = fs.lstatSync(backupKeyQuarantinePath);
      const heldKeyDigest = crypto.createHash('sha256')
        .update(fs.readFileSync(backupKeyQuarantinePath)).digest('hex');
      assertThat(heldKeyMetadata.isFile() && !heldKeyMetadata.isSymbolicLink() &&
          (heldKeyMetadata.mode & 0o777) === 0o600 &&
          heldKeyDigest === backupKeyExpectedDigest,
        'quarantined backup key was not the original private fixture file');
      reportBoolean('only_disposable_backup_key_temporarily_held', true);

      setStage('resume worker and observe durable backup failure');
      let workerReachedTerminal = false;
      try {
        fs.writeFileSync(backupFailureBreakpoint.releasePath, 'resume');
        const terminal = await waitForAdminJobTerminal(
          baseUrl,
          adminAccessToken,
          failedBackupJob.job_id,
        );
        workerReachedTerminal = true;
        assertThat(terminal.action === 'backup' && terminal.status === 'failed' &&
            terminal.result_code === 'backup_failed' &&
            terminal.started_at !== null && terminal.finished_at !== null,
          'manual backup did not persist the expected failed terminal state');
        failedBackupJob = terminal;
        reportBoolean('durable_backup_failed_terminal_state_observed', true);
      } finally {
        if (!fs.existsSync(backupFailureBreakpoint.releasePath)) {
          fs.writeFileSync(backupFailureBreakpoint.releasePath, 'resume');
        }
        if (backupKeyQuarantined && !workerReachedTerminal) {
          try {
            await waitForAdminJobTerminal(
              baseUrl,
              adminAccessToken,
              failedBackupJob.job_id,
              10000,
            );
          } catch (_) {
            await stopServerGroup(debuggerProcess);
            debuggerProcess = undefined;
            await stopServerGroup(serverProcess);
            serverProcess = undefined;
          }
        }
        if (backupKeyQuarantined) restoreDisposableBackupKey();
        if (debuggerProcess) {
          await stopServerGroup(debuggerProcess);
          debuggerProcess = undefined;
        }
      }
      reportBoolean('disposable_backup_key_restored_exactly_after_failure',
        !backupKeyQuarantined && fs.existsSync(backupKeyFile));

      setStage('refresh and verify backup-specific failure in Settings');
      let failedBackupListEvent = await waitForEvent(
        adminEvents,
        (event) => event.route === 'admin-jobs' &&
          event.method === 'GET' &&
          event.requestSequence > failedBackupPostEvent.requestSequence,
      );
      let refreshedFailedBackup;
      for (let attempt = 0; attempt < 8; attempt += 1) {
        assertThat(failedBackupListEvent.status === 200 && failedBackupListEvent.hasBearer,
          'admin backup failure refresh was not an authenticated success');
        const rows = validateJobsPage(await failedBackupListEvent.payloadPromise, 6);
        refreshedFailedBackup = rows.find((job) => job.job_id === failedBackupJob.job_id);
        assertThat(refreshedFailedBackup,
          'failed manual backup was absent from the refreshed durable job list');
        if (['failed', 'succeeded', 'interrupted'].includes(refreshedFailedBackup.status)) break;
        const refreshStart = adminRequestSequence();
        await click(adminPage, 'Refresh instance jobs');
        failedBackupListEvent = await waitForEvent(
          adminEvents,
          adminJobsEvent(adminEvents, 'GET', refreshStart),
        );
      }
      assertThat(refreshedFailedBackup.status === 'failed' &&
          refreshedFailedBackup.result_code === 'backup_failed',
        'Settings refresh did not retain the failed manual backup result');
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Encrypted backup · failed'));
      await waitFor(() => hasVisibleSemanticText(
        adminPage,
        'Encrypted backup failed; check server backup configuration',
      ));
      const failedBackupVisibleText = await pageVisibleText(adminPage);
      assertNoLeaks(failedBackupVisibleText);
      assertThat(!failedBackupVisibleText.includes('Result backup_failed') &&
          !failedBackupVisibleText.includes(backupKeyFile),
        'Settings exposed a raw backup failure code or configured key path');
      reportBoolean('backup_failed_job_renders_safe_guidance', true);

      setStage('verify generic failed backup attempt status');
      const failedStatus = await directApi(baseUrl, 'GET', '/api/v1/admin/backup-status', {
        token: adminAccessToken,
      });
      reportStatus('admin_backup_status_after_failure', failedStatus.status);
      assertThat(failedStatus.status === 200 &&
          exactKeys(failedStatus.body, ['operation', 'last_attempt']) &&
          failedStatus.body.operation === 'backup' &&
          exactKeys(failedStatus.body.last_attempt, [
            'attempted_at', 'result', 'migration_version', 'archive_bytes', 'failure_category',
          ]) &&
          failedStatus.body.last_attempt.result === 'failed' &&
          failedStatus.body.last_attempt.migration_version === null &&
          failedStatus.body.last_attempt.archive_bytes === null &&
          failedStatus.body.last_attempt.failure_category === 'backup_failed',
        'backup status did not return the fixed failed-attempt metadata');
      assertNoLeaks(failedStatus.body);
      const archiveFilesAfterFailure = fs.readdirSync(backupArchiveDir);
      assertThat(archiveFilesAfterFailure.length === 1 &&
          archiveFilesAfterFailure[0] === path.basename(backupArchivePath) &&
          crypto.createHash('sha256').update(fs.readFileSync(backupArchivePath)).digest('hex') ===
            successfulArchiveDigest &&
          !archiveFilesAfterFailure.some((name) => name.includes(failedBackupJob.job_id)),
        'failed backup published an archive or changed the previous successful archive');
      reportBoolean('failed_backup_created_no_archive_and_preserved_previous_archive', true);
      const [instanceAfterBackupFailure, profileAfterBackupFailure] = await Promise.all([
        directApi(baseUrl, 'GET', '/api/v1/instance'),
        directApi(baseUrl, 'GET', '/api/v1/me', { token: adminAccessToken }),
      ]);
      assertThat(instanceAfterBackupFailure.status === 200 &&
          instanceAfterBackupFailure.body?.generation ===
            instanceBeforeBackupFailure.body.generation &&
          profileAfterBackupFailure.status === 200 &&
          profileAfterBackupFailure.body?.account_id === admin.accountId &&
          profileAfterBackupFailure.body?.device_id === admin.deviceId,
        'failed backup changed the live generation or invalidated the administrator session');
      reportBoolean('failed_backup_preserved_live_generation_and_admin_session', true);

      const failureStatusRefreshStart = adminRequestSequence();
      await click(adminPage, 'Refresh backup status');
      const failureStatusRefresh = await waitForEvent(
        adminEvents,
        (event) => event.route === 'backup-status' && event.method === 'GET' &&
          event.requestSequence > failureStatusRefreshStart,
      );
      assertThat(failureStatusRefresh.status === 200 && failureStatusRefresh.hasBearer,
        'failed backup status refresh was not an authenticated success');
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Failed'));
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Failure category'));
      await waitFor(() => hasVisibleSemanticText(adminPage, 'Backup command failed'));
      assertNoLeaks(await pageVisibleText(adminPage));
      reportBoolean('failed_backup_status_card_renders_generic_category', true);
    } finally {
      if (backupKeyQuarantined) {
        if (!fs.existsSync(backupFailureBreakpoint.releasePath)) {
          fs.writeFileSync(backupFailureBreakpoint.releasePath, 'resume');
        }
        try {
          await waitForAdminJobTerminal(
            baseUrl,
            adminAccessToken,
            failedBackupJob.job_id,
            10000,
          );
        } catch (_) {
          await stopServerGroup(debuggerProcess);
          debuggerProcess = undefined;
          await stopServerGroup(serverProcess);
          serverProcess = undefined;
        }
        restoreDisposableBackupKey();
      }
      if (debuggerProcess) {
        await stopServerGroup(debuggerProcess);
        debuggerProcess = undefined;
      }
    }

    setStage('verify request and outcome audit events');
    const audit = await directApi(baseUrl, 'GET', '/api/v1/admin/audit?limit=200', {
      token: adminAccessToken,
    });
    reportStatus('admin_audit_for_jobs', audit.status);
    assertThat(audit.status === 200, 'administrator could not read audit events for maintenance job');
    const auditEvents = validateAuditPage(audit.body);
    const related = auditEvents.filter((event) =>
      event.resource_type === 'admin_job' &&
      ['admin.maintenance_requested', 'admin.maintenance_started', 'admin.maintenance_completed',
        'admin.maintenance_failed', 'admin.maintenance_interrupted',
        'admin.backup_requested', 'admin.backup_started', 'admin.backup_completed',
        'admin.backup_failed', 'admin.backup_interrupted'].includes(event.action));
    const maintenanceEvents = related.filter((event) => event.action.startsWith('admin.maintenance_'));
    const backupEvents = related.filter((event) => event.action.startsWith('admin.backup_'));
    const requested = maintenanceEvents.filter((event) => event.action === 'admin.maintenance_requested');
    const started = maintenanceEvents.filter((event) => event.action === 'admin.maintenance_started');
    const completed = maintenanceEvents.filter((event) => event.action === 'admin.maintenance_completed');
    const maintenanceFailed = maintenanceEvents.filter((event) =>
      event.action === 'admin.maintenance_failed');
    const maintenanceInterrupted = maintenanceEvents.filter((event) =>
      event.action === 'admin.maintenance_interrupted');
    const backupRequested = backupEvents.filter((event) => event.action === 'admin.backup_requested');
    const backupStarted = backupEvents.filter((event) => event.action === 'admin.backup_started');
    const backupCompleted = backupEvents.filter((event) => event.action === 'admin.backup_completed');
    const backupFailed = backupEvents.filter((event) => event.action === 'admin.backup_failed');
    const backupInterrupted = backupEvents.filter((event) => event.action === 'admin.backup_interrupted');
    const maintenanceRequestAuditValid = requested.length === 3 &&
      requested.every((event) => event.scope === 'instance' &&
        event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId &&
        event.result === 'success' && event.source === 'api');
    const maintenanceStartedAuditValid = started.length === 3 &&
      started.every((event) => event.scope === 'instance' &&
        event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId &&
        event.result === 'success' && event.source === 'api');
    const maintenanceCompletedAuditValid = completed.length === 1 &&
      completed[0].scope === 'instance' &&
      completed[0].actor_user_id === admin.accountId &&
      completed[0].actor_device_id === admin.deviceId &&
      completed[0].result === 'success' && completed[0].source === 'api';
    const maintenanceFailedAuditValid = maintenanceFailed.length === 1 &&
      maintenanceFailed[0].scope === 'instance' &&
      maintenanceFailed[0].actor_user_id === admin.accountId &&
      maintenanceFailed[0].actor_device_id === admin.deviceId &&
      maintenanceFailed[0].result === 'failure' && maintenanceFailed[0].source === 'api';
    const maintenanceInterruptedAuditValid = maintenanceInterrupted.length === 1 &&
      maintenanceInterrupted[0].scope === 'instance' &&
      maintenanceInterrupted[0].actor_user_id === admin.accountId &&
      maintenanceInterrupted[0].actor_device_id === admin.deviceId &&
      maintenanceInterrupted[0].result === 'failure' && maintenanceInterrupted[0].source === 'api';
    const backupRequestAuditValid = backupRequested.length === 3 &&
      backupRequested.every((event) => event.scope === 'instance' &&
        event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId &&
        event.result === 'success' && event.source === 'api');
    const backupStartedAuditValid = backupStarted.length === 3 &&
      backupStarted.every((event) => event.scope === 'instance' &&
        event.actor_user_id === admin.accountId && event.actor_device_id === admin.deviceId &&
        event.result === 'success' && event.source === 'api');
    const backupCompletedAuditValid = backupCompleted.length === 1 &&
      backupCompleted[0].scope === 'instance' &&
      backupCompleted[0].actor_user_id === admin.accountId &&
      backupCompleted[0].actor_device_id === admin.deviceId &&
      backupCompleted[0].result === 'success' && backupCompleted[0].source === 'api';
    const backupFailedAuditValid = backupFailed.length === 1 &&
      backupFailed[0].scope === 'instance' &&
      backupFailed[0].actor_user_id === admin.accountId &&
      backupFailed[0].actor_device_id === admin.deviceId &&
      backupFailed[0].result === 'failure' && backupFailed[0].source === 'api';
    const backupInterruptedAuditValid = backupInterrupted.length === 1 &&
      backupInterrupted[0].scope === 'instance' &&
      backupInterrupted[0].actor_user_id === admin.accountId &&
      backupInterrupted[0].actor_device_id === admin.deviceId &&
      backupInterrupted[0].result === 'failure' && backupInterrupted[0].source === 'api';
    const backupResourceGroups = new Map();
    for (const event of backupEvents) {
      if (!backupResourceGroups.has(event.resource_id)) {
        backupResourceGroups.set(event.resource_id, []);
      }
      backupResourceGroups.get(event.resource_id).push(event);
    }
    const orderedActions = (events) => [...events]
      .sort((left, right) => BigInt(left.event_id) < BigInt(right.event_id) ? -1 : 1)
      .map((event) => event.action);
    const maintenanceResourceGroups = new Map();
    for (const event of maintenanceEvents) {
      if (!maintenanceResourceGroups.has(event.resource_id)) {
        maintenanceResourceGroups.set(event.resource_id, []);
      }
      maintenanceResourceGroups.get(event.resource_id).push(event);
    }
    const maintenanceLifecycleOrderValid = maintenanceResourceGroups.size === 3 &&
      [...maintenanceResourceGroups.values()].every((events) => {
        const actions = orderedActions(events);
        return actions.length === 3 &&
          actions[0] === 'admin.maintenance_requested' &&
          actions[1] === 'admin.maintenance_started' &&
          ['admin.maintenance_completed', 'admin.maintenance_failed',
            'admin.maintenance_interrupted'].includes(actions[2]);
      }) && [...maintenanceResourceGroups.values()].filter((events) =>
        orderedActions(events)[2] === 'admin.maintenance_completed').length === 1 &&
      [...maintenanceResourceGroups.values()].filter((events) =>
        orderedActions(events)[2] === 'admin.maintenance_failed').length === 1 &&
      [...maintenanceResourceGroups.values()].filter((events) =>
        orderedActions(events)[2] === 'admin.maintenance_interrupted').length === 1;
    const backupLifecycleOrderValid = backupResourceGroups.size === 3 &&
      [...backupResourceGroups.values()].every((events) => {
        const actions = orderedActions(events);
        return actions.length === 3 &&
          actions[0] === 'admin.backup_requested' &&
          actions[1] === 'admin.backup_started' &&
          ['admin.backup_completed', 'admin.backup_failed',
            'admin.backup_interrupted'].includes(actions[2]);
      }) && [...backupResourceGroups.values()].filter((events) =>
        orderedActions(events)[2] === 'admin.backup_completed').length === 1 &&
      [...backupResourceGroups.values()].filter((events) =>
        orderedActions(events)[2] === 'admin.backup_failed').length === 1 &&
      [...backupResourceGroups.values()].filter((events) =>
        orderedActions(events)[2] === 'admin.backup_interrupted').length === 1;
    const hmacReferencesValid = related.length === 18 && related.every((event) =>
      typeof event.resource_id === 'string' && /^[0-9a-f]{64}$/.test(event.resource_id)) &&
      maintenanceResourceGroups.size === 3 &&
      [...maintenanceResourceGroups.keys()].every((resourceId) =>
        resourceId !== jobId && resourceId !== failedMaintenanceJob.job_id &&
        resourceId !== interruptedMaintenanceJob.job_id) &&
      backupResourceGroups.size === 3 &&
      [...backupResourceGroups.keys()].every((resourceId) =>
        resourceId !== acceptedBackupJob.job_id && resourceId !== failedBackupJob.job_id &&
        resourceId !== interruptedBackupJob.job_id) &&
      maintenanceLifecycleOrderValid && backupLifecycleOrderValid;
    assertThat(maintenanceRequestAuditValid && maintenanceStartedAuditValid &&
        maintenanceCompletedAuditValid && maintenanceFailedAuditValid &&
        maintenanceInterruptedAuditValid &&
        backupRequestAuditValid &&
        backupStartedAuditValid && backupCompletedAuditValid && backupFailedAuditValid &&
        backupInterruptedAuditValid &&
        hmacReferencesValid,
      'request/start/outcome audit events did not match the submitted jobs');
    reportBoolean('maintenance_request_audit_event_valid', true);
    reportBoolean('maintenance_success_failure_and_interruption_audit_events_valid', true);
    reportBoolean('backup_request_audit_event_valid', true);
    reportBoolean('backup_success_failure_and_interruption_audit_events_valid', true);
    reportBoolean('backup_audit_lifecycle_order_valid', true);
    reportBoolean('audit_resource_identifier_hmac_only', true);

    setStage('render real maintenance and backup audit events in Settings');
    await scrollUntilVisibleSemanticText(adminPage, 'Instance admin audit');
    const auditRefreshButton = await hasVisibleSemanticText(adminPage, 'Refresh admin audit')
      ? 'Refresh admin audit'
      : 'Load admin audit';
    const auditCardRefreshStart = adminRequestSequence();
    await click(adminPage, auditRefreshButton);
    const auditCardRefresh = await waitForEvent(adminEvents,
      (event) => event.route === 'admin-audit' && event.method === 'GET' &&
        event.requestSequence > auditCardRefreshStart);
    const auditCardPayload = await auditCardRefresh.payloadPromise;
    reportStatus('admin_audit_card_refresh', auditCardRefresh.status);
    assertThat(auditCardRefresh.hasBearer && auditCardRefresh.status === 200,
      'Settings audit-card refresh was not authenticated and successful');
    const renderedAuditEvents = validateAuditPage(auditCardPayload);
    const expectedRenderedActions = [
      ['admin.maintenance_requested', '管理员已请求维护任务'],
      ['admin.maintenance_started', '管理员维护任务已开始'],
      ['admin.maintenance_completed', '管理员维护任务已完成'],
      ['admin.maintenance_failed', '管理员维护任务失败'],
      ['admin.maintenance_interrupted', '管理员维护任务已中断'],
      ['admin.backup_requested', '管理员已请求备份'],
      ['admin.backup_started', '管理员备份已开始'],
      ['admin.backup_completed', '管理员备份已完成'],
      ['admin.backup_failed', '管理员备份失败'],
      ['admin.backup_interrupted', '管理员备份已中断'],
    ];
    const lifecycleActions = new Set(expectedRenderedActions.map(([action]) => action));
    const expectedLifecycleEvents = related.filter((event) => lifecycleActions.has(event.action));
    const renderedLifecycleEvents = renderedAuditEvents.filter((event) => lifecycleActions.has(event.action));
    const eventFingerprint = (event) => JSON.stringify([
      event.event_id, event.scope, event.actor_user_id, event.actor_device_id, event.action,
      event.resource_type, event.resource_id, event.result, event.occurred_at, event.source,
    ]);
    const expectedFingerprints = new Set(expectedLifecycleEvents.map(eventFingerprint));
    assertThat(expectedLifecycleEvents.length === 18 && renderedLifecycleEvents.length === 18 &&
        renderedLifecycleEvents.every((event) => expectedFingerprints.has(eventFingerprint(event))),
      'Settings audit refresh did not preserve the validated success and failure job events');
    reportBoolean('settings_audit_events_match_validated_writer_events', true);
    await waitFor(async () => {
      for (const [, label] of expectedRenderedActions) {
        if (await hasSemanticText(adminPage, label)) return true;
      }
      return false;
    }, 15000);
    for (const [action, label] of expectedRenderedActions) {
      assertThat(renderedAuditEvents.some((event) => event.action === action),
        'refreshed audit feed omitted a real job lifecycle action');
      await scrollUntilVisibleSemanticText(adminPage, label);
      const rawActionVisible = await hasVisibleSemanticText(adminPage, action);
      reportBoolean(`admin_audit_label_${action.replaceAll('.', '_')}`,
        !rawActionVisible);
      assertThat(!rawActionVisible,
        'Settings audit card displayed a raw maintenance/backup action key');
    }
    reportBoolean('maintenance_backup_lifecycle_actions_rendered', true);

    setStage('scan rendered administrator and member panels for leaks');
    assertNoLeaks(await pageVisibleText(adminPage));
    assertNoLeaks(await pageVisibleText(memberPage));
    assertThat(pageErrors === 0, 'Flutter reported a browser runtime error');
    reportBoolean('secret_filesystem_and_internal_error_text_absent', true);
    reportBoolean('browser_runtime_errors_absent', true);
  } finally {
    await cleanup();
  }
  assertThat(!cleanupFailed, 'temporary test resources did not all clean up');
  setStage('complete');
  console.log('WEB-ADMIN-JOBS-01 passed');
}

main().catch(async (error) => {
  console.error(`stage: failed (${stage}); error type=${error?.name || 'unknown'}; safe assertion=${typeof error?.safeAssertion === 'string' ? error.safeAssertion : 'unclassified'}; safe API statuses=${JSON.stringify(safeApiStatuses)}`);
  await cleanup();
  if (cleanupFailed) console.error('stage: cleanup failed');
  process.exitCode = 1;
});
