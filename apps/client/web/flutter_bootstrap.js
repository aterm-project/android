{{flutter_js}}
{{flutter_build_config}}

// Flutter's generated legacy worker activates immediately and navigates every
// open page. Keep this build identifier as a template token so deployed clients
// can discover a new static bundle without registering that worker.
globalThis.atermiusWebBuildId = {{flutter_service_worker_version}};
globalThis.atermiusProbeWebBuild = async () => {
  const probeUrl = new URL('flutter_bootstrap.js', document.baseURI);
  probeUrl.searchParams.set('atermius_update_probe', String(Date.now()));
  const response = await fetch(probeUrl, {
    cache: 'no-store',
    credentials: 'same-origin',
  });
  if (!response.ok) throw new Error('Web bundle probe failed');
  const source = await response.text();
  const match = source.match(
    /globalThis\.atermiusWebBuildId\s*=\s*['"]([A-Za-z0-9_-]{1,64})['"]/
  );
  if (!match) throw new Error('Web bundle identifier missing');
  return match[1];
};
globalThis.atermiusReloadWebApp = () => window.location.reload();

function isFlutterLegacyWorker(worker) {
  if (!worker) return false;
  try {
    return new URL(worker.scriptURL).pathname.endsWith('/flutter_service_worker.js');
  } catch (_) {
    return false;
  }
}

function showLegacyWorkerMigrationNotice() {
  const container = document.createElement('main');
  container.setAttribute('role', 'alert');
  const title = document.createElement('h1');
  title.textContent = 'Finish retiring the older offline cache';
  const message = document.createElement('p');
  message.textContent =
    'Close other Atermius tabs, then reload this page. The Web app will start after the old cache releases control.';
  const reload = document.createElement('button');
  reload.type = 'button';
  reload.textContent = 'Reload page';
  reload.addEventListener('click', () => window.location.reload());
  container.append(title, message, reload);
  document.body.replaceChildren(container);
}

async function removeFlutterLegacyWorker() {
  if (!('serviceWorker' in navigator)) return false;
  const registrations = await navigator.serviceWorker.getRegistrations();
  const currentUrl = new URL(window.location.href);
  const legacy = registrations.filter((registration) => {
    const scopeUrl = new URL(registration.scope);
    const scopePath = scopeUrl.pathname;
    const descendantPrefix = scopePath.endsWith('/') ? scopePath : `${scopePath}/`;
    const workers = [registration.active, registration.waiting, registration.installing]
      .filter(Boolean);
    const coversCurrentApp = scopeUrl.origin === currentUrl.origin &&
      (currentUrl.pathname === scopePath ||
        currentUrl.pathname.startsWith(descendantPrefix));
    return coversCurrentApp && workers.some(isFlutterLegacyWorker);
  });

  try {
    if (legacy.length > 0) {
      await Promise.all(legacy.map((registration) => registration.unregister()));
      if ('caches' in window) {
        const flutterCache = await caches.open('flutter-app-cache');
        const legacyScopes = legacy.map((registration) =>
          new URL(registration.scope).pathname,
        );
        const currentBundleResource = (relativePath) =>
          /^(?:index\.html|flutter_bootstrap\.js|flutter\.js|flutter_service_worker\.js|main\.dart\.(?:js|mjs|wasm)|version\.json|manifest\.json|favicon\.(?:ico|png))$/.test(relativePath) ||
          /^(?:assets|canvaskit|fonts|icons)\//.test(relativePath);
        for (const request of await flutterCache.keys()) {
          const requestUrl = new URL(request.url);
          if (requestUrl.origin !== currentUrl.origin) continue;
          const belongsToCurrentApp = legacyScopes.some((scopePath) => {
            const prefix = scopePath.endsWith('/') ? scopePath : `${scopePath}/`;
            if (!requestUrl.pathname.startsWith(prefix)) return false;
            return currentBundleResource(requestUrl.pathname.slice(prefix.length));
          });
          if (belongsToCurrentApp) await flutterCache.delete(request);
        }
      }
    }
  } catch (_) {
    showLegacyWorkerMigrationNotice();
    return true;
  }

  const controllerIsLegacy = isFlutterLegacyWorker(navigator.serviceWorker.controller);
  if (!controllerIsLegacy) {
    try {
      sessionStorage.removeItem('atermius.flutter-sw-migration.v1');
    } catch (_) {}
    return false;
  }

  // This migration runs before Flutter creates terminal sessions. Browsers can
  // keep an unregistered worker as the current document's controller until a
  // navigation. Retry that startup navigation twice, then wait for the user
  // instead of launching Flutter under a stale worker or entering a reload loop.
  const migrationKey = 'atermius.flutter-sw-migration.v1';
  let attempts;
  try {
    attempts = Number(sessionStorage.getItem(migrationKey) || '0');
  } catch (_) {
    showLegacyWorkerMigrationNotice();
    return true;
  }
  if (Number.isInteger(attempts) && attempts < 2) {
    try {
      sessionStorage.setItem(migrationKey, String(attempts + 1));
    } catch (_) {
      showLegacyWorkerMigrationNotice();
      return true;
    }
    window.location.reload();
    return true;
  }
  showLegacyWorkerMigrationNotice();
  return true;
}

async function loadAtermiusFlutter() {
  try {
    if (await removeFlutterLegacyWorker()) return;
  } catch (_) {
    if (isFlutterLegacyWorker(navigator.serviceWorker?.controller)) {
      showLegacyWorkerMigrationNotice();
      return;
    }
  }
  _flutter.loader.load({
    config: {
      // Bundle CanvasKit and fallback fonts locally under the same-origin CSP.
      canvasKitBaseUrl: 'canvaskit/',
      fontFallbackBaseUrl: 'fonts/',
    },
    // Omitting serviceWorkerSettings disables Flutter's force-activate worker.
  });
}

loadAtermiusFlutter();
