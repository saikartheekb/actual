import { startBrowserBackend } from '@actual-app/core/platform/client/browser-preload';
import * as Platform from '@actual-app/core/shared/platform';
import { registerSW } from 'virtual:pwa-register';

// oxlint-disable-next-line typescript-paths/absolute-parent-import
import packageJson from '../package.json';

import SharedBrowserServerWorker from './shared-browser-server.ts?sharedworker';

const backendWorkerUrl = new URL('./browser-server.js', import.meta.url);

// This file installs global variables that the app expects.
// Normally these are already provided by electron, but in a real
// browser environment this is where we initialize the backend and
// everything else.

const IS_DEV = import.meta.env.DEV;
const ACTUAL_VERSION = Platform.isPlaywright
  ? '99.9.9'
  : import.meta.env.REACT_APP_REVIEW_ID
    ? '.preview'
    : packageJson.version;

// *** Start the backend ***
//
// The multi-tab coordinator (leader/follower over SharedWorker), the direct
// Worker fallback, and the absurd-sql worker bridge now all live in loot-core
// (packages/loot-core/src/platform/client/browser-preload). We only hand it
// the desktop-specific inputs: the worker asset URL, a SharedWorker factory,
// and the init payload.
const worker = startBrowserBackend({
  backendWorkerUrl,
  initPayload: {
    version: ACTUAL_VERSION,
    isDev: IS_DEV,
    publicUrl: import.meta.env.BASE_URL.slice(0, -1),
    hash: import.meta.env.REACT_APP_BACKEND_WORKER_HASH,
  },
  createSharedWorker: () =>
    new SharedBrowserServerWorker({ name: 'actual-backend' }),
  forceDirectWorker: Platform.isPlaywright || Platform.isIOS,
});

let isUpdateReadyForDownload = false;
let markUpdateReadyForDownload;
const isUpdateReadyForDownloadPromise = new Promise(resolve => {
  markUpdateReadyForDownload = () => {
    isUpdateReadyForDownload = true;
    resolve(true);
  };
});
// Skip SW registration in dev so stale cached assets don't override edits
// between page loads. Plugin code that needs a SW can register one itself.
// In dev there is no SW to install, so applyAppUpdate() can't rely on the
// SW lifecycle to swap the page — fall back to a plain reload so callers
// don't hang on the never-resolving promise inside applyAppUpdate.
const updateSW = IS_DEV
  ? () => window.location.reload()
  : registerSW({
      immediate: true,
      onNeedRefresh: markUpdateReadyForDownload,
    });

global.Actual = {
  IS_DEV,
  ACTUAL_VERSION,

  logToTerminal: (...args) => {
    console.log(...args);
  },

  relaunch: () => {
    window.location.reload();
  },

  reload: () => {
    if (window.navigator.serviceWorker == null) return;

    // Unregister the service worker handling routing and then reload. This should force the reload
    // to query the actual server rather than delegating to the worker
    return window.navigator.serviceWorker
      .getRegistration('/')
      .then(registration => {
        if (registration == null) return;
        return registration.unregister();
      })
      .then(() => {
        window.location.reload();
      });
  },

  startSyncServer: () => {
    // Only for electron app
  },

  stopSyncServer: () => {
    // Only for electron app
  },

  isSyncServerRunning: () => false,

  startOAuthServer: () => {
    return '';
  },

  restartElectronServer: () => {
    // Only for electron app
  },

  openFileDialog: async ({ filters = [] }) => {
    const FILE_ACCEPT_OVERRIDES = {
      // Safari on iOS requires explicit MIME/UTType values for some extensions to allow selection.
      qfx: [
        'application/vnd.intu.qfx',
        'application/x-qfx',
        'application/qfx',
        'application/ofx',
        'application/x-ofx',
        'application/octet-stream',
        'com.intuit.qfx',
      ],
      zip: [
        'application/zip',
        'application/x-zip',
        'application/x-zip-compressed',
        'application/octet-stream',
      ],
      blob: [
        'application/octet-stream',
        'application/x-sqlite3',
      ],
    };

    return new Promise(resolve => {
      let createdElement = false;
      let hasRetriedWithoutAccept = false;
      // Attempt to reuse an already-created file input.
      let input = document.body.querySelector(
        'input[id="open-file-dialog-input"]',
      );
      if (!input) {
        createdElement = true;
        input = document.createElement('input');
      }

      const filter = filters.find(filter => filter.extensions);
      const accept = filter
        ? filter.extensions
            .flatMap(ext => {
              const normalizedExt = ext.startsWith('.')
                ? ext.toLowerCase()
                : `.${ext.toLowerCase()}`;
              const overrides = FILE_ACCEPT_OVERRIDES[ext.toLowerCase()] ?? [];
              return [normalizedExt, ...overrides];
            })
            .join(',')
        : '';

      function configureInput({ relaxedAccept = false } = {}) {
        input.type = 'file';
        input.id = 'open-file-dialog-input';
        input.value = null;
        input.accept = relaxedAccept ? '' : accept;
        input.style.position = 'absolute';
        input.style.top = '0px';
        input.style.left = '0px';
        input.style.display = 'none';
      }

      configureInput();

      input.onchange = e => {
        const file = e.target.files[0];
        if (!file) {
          if (accept && !hasRetriedWithoutAccept) {
            hasRetriedWithoutAccept = true;
            configureInput({ relaxedAccept: true });
            input.click();
            return;
          }
          resolve(null);
          return;
        }

        const filename = file.name.replace(/.*(\.[^.]*)/, 'file$1');
        const reader = new FileReader();
        reader.readAsArrayBuffer(file);
        reader.onload = async function (ev) {
          const filepath = `/uploads/${filename}`;

          void window.__actionsForMenu
            .uploadFile(filename, ev.target.result)
            .then(() => resolve([filepath]));
        };
        reader.onerror = function () {
          alert('Error reading file');
          resolve(null);
        };
      };

      // In Safari the file input has to be in the DOM for change events to
      // reliably fire.
      if (createdElement) {
        document.body.appendChild(input);
      }

      input.click();
    });
  },

  saveFile: (contents, defaultFilename) => {
    const temp = document.createElement('a');
    temp.style = 'display: none';
    temp.download = defaultFilename;
    temp.rel = 'noopener';

    const blob = new Blob([contents]);
    temp.href = URL.createObjectURL(blob);
    temp.dispatchEvent(new MouseEvent('click'));
  },

  openURLInBrowser: url => {
    window.open(url, '_blank');
  },
  openInFileManager: () => {
    // File manager not available in browser
  },
  onEventFromMain: () => {
    // Only for electron app
  },
  isUpdateReadyForDownload: () => isUpdateReadyForDownload,
  waitForUpdateReadyForDownload: () => isUpdateReadyForDownloadPromise,
  applyAppUpdate: async () => {
    updateSW();

    // Wait for the app to reload
    await new Promise(() => {
      // Do nothing
    });
  },

  ipcConnect: () => {
    // Only for electron app
  },
  getServerSocket: async () => {
    return worker;
  },

  setTheme: theme => {
    window.__actionsForMenu.saveGlobalPrefs({ prefs: { theme } });
  },

  moveBudgetDirectory: () => {
    // Only for electron app
  },
};
