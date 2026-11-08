const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const PAM_SERVICE_DIRECTORY = '/etc/pam.d';
const PAM_FIXTURE_SOURCE = path.resolve(
  __dirname,
  '../../apps/client/test/fixtures/pam_keyboard_interactive_fixture.c',
);

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env || process.env,
    encoding: 'utf8',
    timeout: options.timeout || 30000,
    maxBuffer: 1024 * 1024,
  });
  if (result.error || result.status !== 0) {
    throw new Error(`${path.basename(command)} fixture command failed`);
  }
  return result.stdout || '';
}

function createKeyboardInteractivePamFixture({
  tempRoot,
  expectedCode,
  expectedOtp,
}) {
  if (!/^[A-Za-z0-9_-]{16,96}$/.test(expectedCode) ||
      !/^\d{6}$/.test(expectedOtp)) {
    throw new Error('PAM fixture response values are outside their safe format');
  }
  const compiler = process.env.CC || 'cc';
  const modulePath = path.join(tempRoot, 'libatermius_web_kbdint.so');
  const writerPath = `${modulePath}.service-writer`;
  const serviceName = `atermius-kbdint-${process.pid.toString(16)}-${
    require('node:crypto').randomBytes(8).toString('hex')}`;
  const servicePath = path.join(PAM_SERVICE_DIRECTORY, serviceName);
  let ownsService = false;

  if (!fs.existsSync(PAM_FIXTURE_SOURCE) || !fs.existsSync(PAM_SERVICE_DIRECTORY)) {
    throw new Error('Linux OpenSSH/PAM fixture prerequisites are unavailable');
  }
  run(compiler, [
    '-std=c11', '-shared', '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror',
    '-Wno-unused-parameter',
    `-DATERMIUS_PAM_EXPECTED_CODE=${JSON.stringify(expectedCode)}`,
    `-DATERMIUS_PAM_EXPECTED_OTP=${JSON.stringify(expectedOtp)}`,
    '-o', modulePath, PAM_FIXTURE_SOURCE, '-lpam',
  ]);
  run(compiler, [
    '-std=c11', '-DPAM_SERVICE_WRITER', '-O2', '-Wall', '-Wextra', '-Werror',
    '-o', writerPath, PAM_FIXTURE_SOURCE,
  ]);
  fs.chmodSync(modulePath, 0o700);
  fs.chmodSync(writerPath, 0o700);

  const serviceContents = [
    `auth requisite ${modulePath}`,
    'account required pam_permit.so',
    'session required pam_permit.so',
    '',
  ].join('\n');
  const created = spawnSync(writerPath, [servicePath, serviceContents], {
    encoding: 'utf8',
    timeout: 5000,
  });
  if (created.error || created.status !== 0) {
    throw new Error('could not create the exclusive temporary PAM service');
  }
  ownsService = true;
  const serviceStat = fs.statSync(servicePath);
  if (serviceStat.uid !== 0 || (serviceStat.mode & 0o777) !== 0o600) {
    fs.unlinkSync(servicePath);
    ownsService = false;
    throw new Error('temporary PAM service ownership or permissions are unsafe');
  }

  return {
    serviceName,
    servicePath,
    modulePath,
    expectedCode,
    expectedOtp,
    cleanup() {
      if (!ownsService) return;
      const current = fs.lstatSync(servicePath);
      if (!current.isFile() || current.uid !== 0 ||
          (current.mode & 0o777) !== 0o600 ||
          path.dirname(servicePath) !== PAM_SERVICE_DIRECTORY ||
          path.basename(servicePath) !== serviceName) {
        throw new Error('refusing to remove a PAM service outside this fixture');
      }
      fs.unlinkSync(servicePath);
      ownsService = false;
    },
  };
}

module.exports = { createKeyboardInteractivePamFixture };
