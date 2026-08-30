import { createContext, useContext } from 'react';
import type { Session } from './session';

// The session, resolved ONCE in main.tsx before React mounts, then read from
// here. It is deliberately not state: the role cannot change inside a document
// life (signing out navigates), so making it stateful would only invite a
// render where the role is still unknown — which is the exact bug class this
// whole change exists to remove.

const SessionContext = createContext<Session>({ role: 'anon', name: '' });

export const SessionProvider = SessionContext.Provider;

export function useSession(): Session {
  return useContext(SessionContext);
}

/** True when the tab belongs to a self-registered walk-in account. */
export function useIsWalkin(): boolean {
  return useSession().role === 'walkin';
}
