// Operator authentication for the HTTPS server's admin/observability plane.
// The token is entered interactively and kept only in this tab's sessionStorage:
// it is never compiled into the public bundle, put in a URL, or logged.

const ADMIN_TOKEN_KEY = 'kernelHive.adminToken';

export function getAdminToken(): string | null {
  try {
    const token = window.sessionStorage.getItem(ADMIN_TOKEN_KEY)?.trim();
    return token || null;
  } catch {
    return null;
  }
}

// Only the console operator-login helpers below use these now (golden restore no
// longer needs a token), so they stay module-local — exporting them would trip
// knip's unused-export check.
function requestAdminToken(): string | null {
  const current = getAdminToken();
  if (current) return current;
  const entered = window.prompt('Operator token (kept only in this browser tab):')?.trim();
  if (!entered) return null;
  try { window.sessionStorage.setItem(ADMIN_TOKEN_KEY, entered); } catch { /* noop */ }
  return entered;
}

function clearAdminToken(): void {
  try { window.sessionStorage.removeItem(ADMIN_TOKEN_KEY); } catch { /* noop */ }
}

declare global {
  interface Window {
    __kernelHiveAdminLogin?: () => boolean;
    __kernelHiveAdminLogout?: () => void;
  }
}

// Console helpers prompt for the value, so it never appears in DevTools command
// history. Authenticate the tab before enqueuing an operator command.
if (typeof window !== 'undefined') {
  window.__kernelHiveAdminLogin = () => requestAdminToken() !== null;
  window.__kernelHiveAdminLogout = clearAdminToken;
}
