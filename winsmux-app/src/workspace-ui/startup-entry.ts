/// <reference types="vite/client" />
import { isTauri } from '@tauri-apps/api/core';
import { getCurrentWebviewWindow } from '@tauri-apps/api/webviewWindow';

import './startup.css';

import { captureSecondaryRoute, type StartupRoute, type SecondaryCapture } from './startup-location';
export { selectStartupRoute, startupLocationAllowed, validatePopoutPayload, localPreviewUrl } from './startup-location';
export type { PopoutPayload, StartupRoute } from './startup-location';

let started = false;
async function start() {
  if (started) return; started = true;
  const legacy = document.getElementById('app-shell');
  let capture: SecondaryCapture | null = null;
  const fail = () => {
    capture?.report('failed'); capture?.dispose();
    legacy?.remove();
    const message = document.createElement('p'); message.setAttribute('role', 'status');
    message.textContent = 'この画面の起動経路を確認できません。'; document.body.append(message);
  };
  try {
    const native = isTauri();
    const label = native ? getCurrentWebviewWindow().label : '';
    const captured = captureSecondaryRoute(native, label, location.href, localStorage, callback => { window.addEventListener('storage', callback); return () => window.removeEventListener('storage', callback); });
    const route: StartupRoute = captured.route; capture = captured.capture;
    if (route.kind === 'closed') { fail(); return; }
    if (route.kind === 'main') {
      legacy?.remove();
      const root = document.createElement('main'); root.id = 'workspace-startup'; document.body.append(root);
      const { mountWorkspaceMain } = await import('./startup-mount');
      await mountWorkspaceMain(root);
    } else {
      await import('../styles.css');
      const { mountSecondarySurface } = await import('./startup-secondary');
      await mountSecondarySurface(route.payload, capture);
    }
  } catch { fail(); }
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => { void start(); }, { once: true });
else void start();
