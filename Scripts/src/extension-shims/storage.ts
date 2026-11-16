// chrome.storage as Chrome has it.

import { resolved } from './callbacks';
import { createEvent } from './events';
import { fill } from './members';
import type { Shim } from './types';

export function fillStorage(shim: Shim): void {
  fill(shim, 'storage', {
    managed: { get: resolved({}), getBytesInUse: resolved(0), onChanged: createEvent() },
    AccessLevel: {
      TRUSTED_CONTEXTS: 'TRUSTED_CONTEXTS',
      TRUSTED_AND_UNTRUSTED_CONTEXTS: 'TRUSTED_AND_UNTRUSTED_CONTEXTS',
    },
  });
}

/**
 * A value as Chrome passes it between an extension's contexts and keeps it
 * in storage: through JSON. WebKit takes the object as it is, and one with a
 * cycle or a framework's reactive wrappers in it brings down its web
 * process, over and over as the page tries again; through JSON it's plain
 * data, and a cycle throws, as in Chrome.
 */
export function asJSON(value: unknown): unknown {
  return value === null || typeof value !== 'object' ? value : JSON.parse(JSON.stringify(value));
}

/** Items as WebKit stores them: plain data (see `asJSON`), also from an object with another prototype. */
export function plainItems(items: unknown): unknown {
  return asJSON(items);
}

/**
 * Items built with Object.create(null) — Chrome stores them, WebKit
 * throws that an object is expected.
 */
export function storePlainItems({ chrome, put }: Shim): void {
  for (const area of ['local', 'sync', 'session']) {
    const store = chrome.storage && chrome.storage[area];
    if (!store || typeof store.set !== 'function') continue;
    const set = store.set.bind(store);
    put(store, 'set', (items: unknown, ...rest: unknown[]) => set(plainItems(items), ...rest));
  }
}
