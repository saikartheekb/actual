import { run as runMigrations } from './src/migrations';

// Suppress the ExperimentalWarning emitted by the built-in `node:sqlite`
// module until it is fully stabilized. The sync-server uses `node:sqlite`
// instead of `better-sqlite3` so it can run on platforms without native
// module toolchains.
const originalEmitWarning = process.emitWarning.bind(process);
process.emitWarning = (warning, ...args) => {
  if (
    warning &&
    typeof warning === 'object' &&
    'name' in warning &&
    warning.name === 'ExperimentalWarning' &&
    'message' in warning &&
    typeof warning.message === 'string' &&
    warning.message.includes('SQLite')
  ) {
    return;
  }

  if (
    typeof warning === 'string' &&
    args[0] === 'ExperimentalWarning' &&
    warning.includes('SQLite')
  ) {
    return;
  }

  // oxlint-disable-next-line @typescript-eslint/no-explicit-any
  (originalEmitWarning as any)(warning, ...args);
};

runMigrations()
  .then(() => {
    //import the app here becasue initial migrations need to be run first - they are dependencies of the app.js
    void import('./src/app.js').then(app => app.run()); // run the app
  })
  .catch(err => {
    console.log('Error starting app:', err);
    process.exit(1);
  });
