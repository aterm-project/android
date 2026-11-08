/*
 * WEB-APP-UPDATE-MIGRATION: run the repository's actual Web bootstrap worker
 * retirement path on a secure HTTPS origin with a synthetic legacy worker.
 * The worker and profile are fixture-only; no production credentials/API are
 * involved.
 */

const fs = require('node:fs');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const ROOT = path.resolve(__dirname, '../..');
const BOOTSTRAP_SOURCE = path.join(ROOT, 'apps/client/web/flutter_bootstrap.js');
const CHROMIUM_EXECUTABLE = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE;

function assertThat(condition, message) {
  if (!condition) throw new Error(message);
}

function runOpenSsl(args) {
  const result = spawnSync('openssl', args, {
    encoding: 'utf8',
    timeout: 15000,
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  if (result.error || result.status !== 0) {
    throw new Error('temporary HTTPS certificate generation failed');
  }
}

async function closeServer(server) {
  if (!server || !server.listening) return;
  await new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
    server.closeAllConnections?.();
  });
}

async function main() {
  assertThat(fs.existsSync(BOOTSTRAP_SOURCE), 'Web bootstrap source is missing');

  let browser;
  let context;
  let page;
  let server;
  let tempRoot;
  let stage = 'setup';
  let mainPageRequests = 0;
  let pageErrors = 0;
  let cleanupFailed = false;

  try {
    tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'atermius-web-update-migration-'));
    const keyPath = path.join(tempRoot, 'https.key');
    const certPath = path.join(tempRoot, 'https.crt');
    runOpenSsl([
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', keyPath, '-out', certPath, '-days', '1',
      '-subj', '/CN=127.0.0.1',
      '-addext', 'subjectAltName=IP:127.0.0.1',
    ]);

    stage = 'prepare actual bootstrap with Flutter loader stubs';
    const bootstrap = fs.readFileSync(BOOTSTRAP_SOURCE, 'utf8')
      .replace('{{flutter_js}}',
        'globalThis._flutter = { loader: { load() { globalThis.__appStarted = true; } } };')
      .replace('{{flutter_build_config}}', 'globalThis._flutter.buildConfig = {};')
      .replace('{{flutter_service_worker_version}}', "'migration-fixture-build'");
    assertThat(!bootstrap.includes('{{flutter_'),
      'Flutter bootstrap template tokens were not fully replaced');

    const html = Buffer.from(
      '<!doctype html><html><head><meta charset="utf-8"></head><body>' +
      '<script src="/app/flutter_bootstrap.js"></script></body></html>',
    );
    const worker = Buffer.from(
      "self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));\n" +
      "self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));\n",
    );
    const assets = new Map([
      ['/app/index.html', { body: html, type: 'text/html; charset=utf-8' }],
      ['/app/flutter_bootstrap.js', { body: Buffer.from(bootstrap), type: 'text/javascript; charset=utf-8' }],
      ['/app/flutter_service_worker.js', { body: worker, type: 'text/javascript; charset=utf-8' }],
      ['/other/flutter_service_worker.js', { body: worker, type: 'text/javascript; charset=utf-8' }],
    ]);

    server = https.createServer({
      key: fs.readFileSync(keyPath),
      cert: fs.readFileSync(certPath),
    }, (request, response) => {
      let pathname;
      try {
        pathname = new URL(request.url, 'https://127.0.0.1').pathname;
      } catch (_) {
        response.writeHead(400).end();
        return;
      }
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        response.writeHead(405).end();
        return;
      }
      if (pathname === '/app/index.html') mainPageRequests++;
      const asset = assets.get(pathname);
      if (!asset) {
        response.writeHead(404, { 'Cache-Control': 'no-store' }).end();
        return;
      }
      response.writeHead(200, {
        'Content-Type': asset.type,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      });
      response.end(request.method === 'HEAD' ? undefined : asset.body);
    });
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const baseUrl = 'https://127.0.0.1:' + server.address().port;
    assertThat(new URL(baseUrl).protocol === 'https:', 'fixture is not a secure origin');

    stage = 'launch isolated Chromium context';
    const launchOptions = { headless: true, args: ['--ignore-certificate-errors'] };
    if (CHROMIUM_EXECUTABLE) launchOptions.executablePath = CHROMIUM_EXECUTABLE;
    browser = await chromium.launch(launchOptions);
    context = await browser.newContext({
      ignoreHTTPSErrors: true,
      serviceWorkers: 'allow',
    });
    page = await context.newPage();
    page.on('pageerror', () => { pageErrors++; });

    stage = 'load the current bootstrap on HTTPS';
    const firstResponse = await page.goto(baseUrl + '/app/index.html', {
      waitUntil: 'load',
    });
    assertThat(firstResponse?.status() === 200, 'bootstrap fixture did not load');
    await page.waitForFunction(() => globalThis.__appStarted === true, {
      timeout: 10000,
    });

    stage = 'seed known and unrelated cache entries';
    const seeded = await page.evaluate(async () => {
      const cache = await caches.open('flutter-app-cache');
      const paths = [
        '/app/main.dart.js',
        '/app/assets/legacy-font.bin',
        '/app/unrelated-user-data.bin',
        '/other/main.dart.js',
      ];
      for (const pathname of paths) {
        await cache.put(
          new Request(new URL(pathname, location.origin)),
          new Response('fixture-cache-byte'),
        );
      }
      return (await cache.keys()).length;
    });
    assertThat(seeded === 4, 'cache fixture did not seed all expected entries');

    stage = 'register matching and out-of-scope legacy workers';
    const registrationState = await page.evaluate(async () => {
      await navigator.serviceWorker.register(
        '/other/flutter_service_worker.js',
        { scope: '/other/' },
      );
      await navigator.serviceWorker.register(
        '/app/flutter_service_worker.js',
        { scope: '/app/' },
      );
      await navigator.serviceWorker.ready;
      if (!navigator.serviceWorker.controller) {
        await Promise.race([
          new Promise((resolve) => navigator.serviceWorker.addEventListener(
            'controllerchange', resolve, { once: true },
          )),
          new Promise((resolve) => setTimeout(resolve, 5000)),
        ]);
      }
      return {
        secure: isSecureContext,
        controller: navigator.serviceWorker.controller?.scriptURL ?? null,
        scopes: (await navigator.serviceWorker.getRegistrations())
          .map((registration) => new URL(registration.scope).pathname).sort(),
      };
    });
    assertThat(registrationState.secure, 'service worker did not run in a secure context');
    assertThat(registrationState.controller?.endsWith('/app/flutter_service_worker.js'),
      'matching legacy worker did not control the fixture page');
    assertThat(registrationState.scopes.includes('/app/') &&
      registrationState.scopes.includes('/other/'),
    'both in-scope and out-of-scope registrations were not installed');

    stage = 'retire only the matching legacy worker and load the app';
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForFunction(() => globalThis.__appStarted === true, {
      timeout: 15000,
    });
    await page.waitForTimeout(500);

    const finalState = await page.evaluate(async () => {
      const registrations = await navigator.serviceWorker.getRegistrations();
      const cache = await caches.open('flutter-app-cache');
      const paths = (await cache.keys())
        .map((request) => new URL(request.url).pathname).sort();
      return {
        started: globalThis.__appStarted === true,
        controller: navigator.serviceWorker.controller?.scriptURL ?? null,
        scopes: registrations.map((registration) =>
          new URL(registration.scope).pathname).sort(),
        cachePaths: paths,
        secure: isSecureContext,
      };
    });

    assertThat(finalState.started, 'application loader did not start after migration');
    assertThat(finalState.secure, 'final page left the secure origin');
    assertThat(!finalState.scopes.includes('/app/'),
      'matching legacy service worker registration remains');
    assertThat(finalState.scopes.includes('/other/'),
      'out-of-scope service worker was removed');
    assertThat(finalState.controller === null,
      'current app remains controlled by the retired legacy worker');
    for (const removed of ['/app/main.dart.js', '/app/assets/legacy-font.bin']) {
      assertThat(!finalState.cachePaths.includes(removed),
        'known current-bundle cache entry remains');
    }
    for (const preserved of ['/app/unrelated-user-data.bin', '/other/main.dart.js']) {
      assertThat(finalState.cachePaths.includes(preserved),
        'unrelated cache entry was removed');
    }
    assertThat(mainPageRequests >= 3 && mainPageRequests <= 4,
      'legacy-worker startup did not settle within the bounded navigation count');
    assertThat(pageErrors === 0, 'migration fixture produced a browser page error');

    console.log('WEB-APP-UPDATE-MIGRATION passed: the repository bootstrap ran on HTTPS, removed only the matching legacy worker and known bundle cache entries, preserved out-of-scope worker/cache data, and started after bounded reload navigation.');
  } catch (error) {
    console.error('WEB-APP-UPDATE-MIGRATION failed at stage: ' + stage);
    process.exitCode = 1;
  } finally {
    try { if (context) await context.close(); } catch (_) { cleanupFailed = true; }
    try { if (browser) await browser.close(); } catch (_) { cleanupFailed = true; }
    try { await closeServer(server); } catch (_) { cleanupFailed = true; }
    try {
      if (tempRoot) fs.rmSync(tempRoot, { recursive: true, force: true });
      if (tempRoot && fs.existsSync(tempRoot)) cleanupFailed = true;
    } catch (_) {
      cleanupFailed = true;
    }
    if (cleanupFailed) {
      console.error('WEB-APP-UPDATE-MIGRATION cleanup failed');
      process.exitCode = 1;
    } else {
      console.log('WEB-APP-UPDATE-MIGRATION cleanup passed');
    }
  }
}

main().catch(() => {
  console.error('WEB-APP-UPDATE-MIGRATION failed before fixture cleanup');
  process.exitCode = 1;
});
