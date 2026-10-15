import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

/** Keep the MSI library target in the same Cargo invocation as the desktop binary. */
export function desktopBuildArguments(args) {
  let command = 0;
  while (args[command] === '--verbose' || /^-v+$/u.test(args[command] ?? '')) command++;
  if (args[command] !== 'build') return [...args];

  const separator = args.indexOf('--', command + 1);
  const sdkEnd = separator === -1 ? args.length : separator;
  if (args.slice(command + 1, sdkEnd).some(arg => arg === '-h' || arg === '--help')) return [...args];
  if (separator === -1) return [...args, '--', '--lib'];
  return args.slice(separator + 1).includes('--lib') ? [...args] : [...args, '--lib'];
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  const { run, logError } = createRequire(import.meta.url)('@tauri-apps/cli');
  // Match the pinned SDK's tauri.js Promise and failure behavior without a shell.
  run(desktopBuildArguments(process.argv.slice(2)), 'npm run tauri').catch(error => {
    logError(error.message);
    process.exit(1);
  });
}
