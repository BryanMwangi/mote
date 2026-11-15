// Proxies an extension asks for, carried out by the browser
// (ExtensionProxy.swift): chrome.proxy.settings is answered there, and
// Firefox's proxy.onRequest here. WebKit takes one proxy for all of a
// website data store's loads, not one per request, so the listener is asked
// about a sample page, again every few seconds — an add-on's answer changes
// as it connects and disconnects, without adding a listener again — and the
// browser is told when the answer changes. The proxy's sign-in comes from the
// extension's webRequest.onAuthRequired listeners, asked as for a proxy.

import { createEvent, type Listener } from './events';
import { putNamespace } from './namespaces';
import { setting } from './settings';
import type { Shim } from './types';

/** A proxy as the browser takes it. */
export interface ProxyChoice {
  type: 'http' | 'https' | 'socks';
  host: string;
  port: number;
  username?: string;
  password?: string;
}

/** What a page load is asked as. */
const SAMPLE = 'https://www.example.com/';
/** How often the listener is asked again. */
const EVERY = 2000;

/** The extension's webRequest.onAuthRequired listeners (web-request.ts keeps them). */
export const authListeners = new Set<Listener>();

/**
 * A listener's answer (a proxy, a list of them to try in turn, or DIRECT) as
 * the browser takes it: the first proxy it can use, or null for none.
 */
export function proxyChoice(answer: unknown): ProxyChoice | null {
  const first: unknown = Array.isArray(answer) ? answer[0] : answer;
  if (!first || typeof first !== 'object') return null;
  const info = first as Record<string, unknown>;
  const kind = String(info.type ?? '').toLowerCase();
  const type =
    kind === 'http' || kind === 'https' ? kind : kind === 'socks' || kind === 'socks5' ? 'socks' : null;
  const port = Number(info.port);
  if (
    !type ||
    typeof info.host !== 'string' ||
    !info.host ||
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65_535
  ) {
    return null;
  }
  const choice: ProxyChoice = { type, host: info.host, port };
  // A sign-in given with it: names for SOCKS, a Basic header for HTTP ones.
  if (typeof info.username === 'string' && typeof info.password === 'string') {
    choice.username = info.username;
    choice.password = info.password;
  } else if (typeof info.proxyAuthorizationHeader === 'string') {
    const basic = /^basic\s+(.+)$/i.exec(info.proxyAuthorizationHeader.trim());
    try {
      const words = basic?.[1] ? atob(basic[1]) : '';
      const colon = words.indexOf(':');
      if (colon > 0) {
        choice.username = words.slice(0, colon);
        choice.password = words.slice(colon + 1);
      }
    } catch {}
  }
  return choice;
}

/** A listener's answer, given by returning it, a promise, or (Chrome's asyncBlocking) a callback. */
function answerOf(listener: Listener, details: unknown): Promise<unknown> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(undefined), 3000);
    const done = (value: unknown) => {
      clearTimeout(timer);
      resolve(value);
    };
    try {
      const returned = listener(details, done);
      if (returned !== undefined) void Promise.resolve(returned).then(done, () => done(undefined));
    } catch {
      done(undefined);
    }
  });
}

/** The sign-in the extension gives for `choice`, asked as the proxy asking. */
async function signIn(choice: ProxyChoice): Promise<ProxyChoice> {
  if (choice.username !== undefined) return choice;
  for (const listener of authListeners) {
    const answer = await answerOf(listener, {
      requestId: 'mote-proxy',
      url: SAMPLE,
      method: 'GET',
      frameId: 0,
      parentFrameId: -1,
      tabId: -1,
      type: 'main_frame',
      timeStamp: Date.now(),
      isProxy: true,
      scheme: 'basic',
      realm: '',
      challenger: { host: choice.host, port: choice.port },
      statusCode: 407,
      statusLine: 'HTTP/1.1 407 Proxy Authentication Required',
    });
    const given = (answer as { authCredentials?: { username?: unknown; password?: unknown } } | undefined)
      ?.authCredentials;
    if (typeof given?.username === 'string' && typeof given.password === 'string') {
      return { ...choice, username: given.username, password: given.password };
    }
  }
  return choice;
}

export function defineProxy(shim: Shim): void {
  const onRequest = createEvent();
  putNamespace(shim, 'proxy', {
    settings: setting(shim, 'proxy.settings'),
    onRequest,
    onError: createEvent(),
    onProxyError: createEvent(),
  });
  if (!shim.background) return;

  /** What the browser was last told, as text; null before anything. */
  let told: string | null = null;
  /** The proxy last signed in for, so a sign-in is asked once per proxy. */
  let signedFor = '';
  let signed: ProxyChoice | null = null;
  let timer: ReturnType<typeof setInterval> | undefined;

  const check = async () => {
    let choice: ProxyChoice | null = null;
    for (const listener of [...onRequest.listeners]) {
      choice = proxyChoice(
        await answerOf(listener, {
          requestId: 'mote-proxy',
          url: SAMPLE,
          method: 'GET',
          frameId: 0,
          parentFrameId: -1,
          tabId: -1,
          type: 'main_frame',
          timeStamp: Date.now(),
        }),
      );
      if (choice) break;
    }
    if (choice) {
      const key = `${choice.type}://${choice.host}:${choice.port}`;
      if (key !== signedFor || !signed) {
        signedFor = key;
        signed = await signIn(choice);
      }
      choice = signed;
    }
    const text = JSON.stringify(choice);
    // Told when it changes, and once at the start, so a proxy left from
    // before is cleared.
    if (text === told) return;
    told = text;
    void shim.native('proxy.apply', [choice]).catch(() => undefined);
  };

  const add = onRequest.addListener.bind(onRequest);
  const remove = onRequest.removeListener.bind(onRequest);
  onRequest.addListener = (listener: Listener) => {
    add(listener);
    timer ??= setInterval(() => void check(), EVERY);
    void check();
    return undefined;
  };
  onRequest.removeListener = (listener: Listener) => {
    remove(listener);
    if (!onRequest.hasListeners() && timer !== undefined) {
      clearInterval(timer);
      timer = undefined;
    }
    void check();
    return undefined;
  };
}
