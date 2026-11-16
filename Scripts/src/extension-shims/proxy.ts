// Proxies an extension asks for, carried out by the browser
// (ExtensionProxy.swift): chrome.proxy.settings is answered there, and
// Firefox's proxy.onRequest here. WebKit takes proxies for all of a website
// data store's loads, not one per request, so the listener is asked about a
// sample page, again every few seconds — an add-on's answer changes as it
// connects and disconnects, without adding a listener again — and the browser
// is told when the answer changes.
//
// A proxy's sign-in comes from the extension's webRequest.onAuthRequired
// listeners, asked as for a proxy, whenever the browser finds a proxy wants
// one it doesn't have: right after the extension sets it, and later over a
// port the browser keeps to the worker while the extension holds a proxy,
// which also brings proxy.settings.onChange and proxy.onProxyError.

import { createEvent, type Listener, type ShimEvent } from './events';
import { putNamespace } from './namespaces';
import { setting } from './settings';
import type { Shim, WebKitObject } from './types';
import { asksFor } from './unavailable';

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
/** The native app name the browser hears this port on (ExtensionProxy.portName). */
export const PROXY_APPLICATION = 'mote.proxy';

/** The extension's webRequest.onAuthRequired listeners (web-request.ts keeps them). */
export const authListeners = new Set<Listener>();

/**
 * A listener's answer (a proxy, a list of them to try in turn, or DIRECT) as
 * the browser takes it: the first proxy, or null for none. As in Firefox
 * (ProxyChannelFilter), an answer it can't use means none, never a stalled
 * request: SOCKS4 and MASQUE, which Network can't speak, among them.
 */
export function proxyChoice(answer: unknown): ProxyChoice | null {
  const first: unknown = Array.isArray(answer) ? answer[0] : answer;
  if (!first || typeof first !== 'object') return null;
  const info = first as Record<string, unknown>;
  const kind = String(info.type ?? '').toLowerCase();
  // "proxy" is Firefox's other name for HTTP.
  const type =
    kind === 'http' || kind === 'proxy'
      ? 'http'
      : kind === 'https'
        ? kind
        : kind === 'socks' || kind === 'socks5'
          ? 'socks'
          : null;
  const port = Number(info.port);
  if (
    !type ||
    typeof info.host !== 'string' ||
    !info.host ||
    /\s/.test(info.host) ||
    // Only HTTP proxies take an authorization header.
    (type === 'socks' && info.proxyAuthorizationHeader != null) ||
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

/** A proxy that wants a sign-in, as the browser finds it out. */
export interface Asked {
  host: string;
  port: string | number;
  type?: string;
  scheme?: string;
  realm?: string;
}

/** A sign-in the extension gave, for the browser. */
export interface Given {
  host: string;
  port: number;
  username: string;
  password: string;
}

/**
 * Each ask is a request of its own, as in Chrome: a listener that refuses a
 * request id it has answered before (thinking its sign-in failed) answers
 * the next one.
 */
let nextRequest = Math.floor(Math.random() * 1e6) + 1e6;

/**
 * The extension's sign-in for a proxy, asked as the proxy asking, with the
 * scheme and realm it asks with (a listener may answer only its own realm);
 * null when none gives one.
 */
export async function signIn(asked: Asked): Promise<Given | null> {
  const port = Number(asked.port);
  const type = asked.type || 'https';
  for (const listener of [...authListeners]) {
    const answer = await answerOf(listener, {
      requestId: String(nextRequest++),
      url: SAMPLE,
      method: 'GET',
      frameId: 0,
      parentFrameId: -1,
      tabId: -1,
      type: 'main_frame',
      timeStamp: Date.now(),
      isProxy: true,
      scheme: asked.scheme || 'basic',
      realm: asked.realm ?? '',
      challenger: { host: asked.host, port },
      proxyInfo: { host: asked.host, port, type, username: '', proxyDNS: false, failoverTimeout: 10 },
      statusCode: 407,
      statusLine: 'HTTP/1.1 407 Proxy Authentication Required',
    });
    const given = (answer as { authCredentials?: { username?: unknown; password?: unknown } } | undefined)
      ?.authCredentials;
    if (typeof given?.username === 'string' && typeof given.password === 'string') {
      return { host: asked.host, port, username: given.username, password: given.password };
    }
  }
  return null;
}

/** Signs in to each proxy asked, and gives the browser what came. */
async function signInTo(shim: Shim, asks: unknown): Promise<void> {
  if (!Array.isArray(asks) || !asks.length) return;
  const given: Given[] = [];
  for (const asked of asks as Asked[]) {
    const one = await signIn(asked);
    if (one) given.push(one);
    // Test runs: why a proxy went without a sign-in.
    else if (shim.config?.verbose) {
      void shim
        .native('debug.error', [
          `proxy sign-in: none of ${authListeners.size} listeners gave one for ${asked.host}`,
        ])
        .catch(() => undefined);
    }
  }
  if (given.length) await shim.native('proxy.credentials', [given]).catch(() => undefined);
}

/** The sign-in round under way, if one is: a second waits on it rather than asking again. */
let signingIn: Promise<void> | null = null;

/** Whatever sign-in the extension's proxies still want. */
function signInNow(shim: Shim): Promise<void> {
  signingIn ??= (async () => {
    try {
      await signInTo(shim, await shim.native('proxy.challenge', []).catch(() => null));
    } finally {
      signingIn = null;
    }
  })();
  return signingIn;
}

/**
 * The page a listener is asked about: the tab in front, with its id, as
 * Firefox asks about a tab's request — a listener may look its tab up
 * (tabs.get) to decide; the sample page when no tab shows a website.
 */
export async function samplePage(shim: Shim): Promise<{ url: string; tabId: number }> {
  try {
    const tabs = (await shim.chrome.tabs.query({ active: true, lastFocusedWindow: true })) as {
      id?: number;
      url?: string;
    }[];
    const tab = tabs.find((t) => typeof t.id === 'number' && /^https?:/.test(t.url ?? ''));
    if (tab) return { url: tab.url as string, tabId: tab.id as number };
  } catch {}
  return { url: SAMPLE, tabId: -1 };
}

/** Calls an event's listeners, each failure its own. */
function fire(event: ShimEvent, ...args: unknown[]): void {
  for (const listener of [...event.listeners]) {
    try {
      listener(...args);
    } catch (e) {
      setTimeout(() => {
        throw e;
      });
    }
  }
}

/** What the browser says on the port. */
interface Told {
  ready?: boolean;
  signIn?: boolean;
  /** Where a page on this address goes, as proxy.onRequest answers: asked by the relay for each host. */
  route?: { n: number; url: string };
  change?: unknown;
  error?: { fatal?: boolean; error?: string; details?: string };
}

/**
 * The port the browser tells the worker things on, opened while the
 * extension holds a proxy (the browser closes one that holds none). WebKit
 * drops what a worker posts on a port it has only just opened, so the
 * greeting is said again until the browser answers.
 */
function openPort(shim: Shim, heard: (told: Told, reply: (message: unknown) => void) => void): () => void {
  let port: WebKitObject = null;
  return () => {
    if (port || typeof shim.runtime?.connectNative !== 'function') return;
    let ready = false;
    let tries = 0;
    try {
      port = shim.runtime.connectNative(PROXY_APPLICATION);
    } catch {
      port = null;
      return;
    }
    const mine = port;
    const again = (): void => {
      if (ready || port !== mine || tries++ >= 20) return;
      try {
        mine.postMessage({ hello: true });
      } catch {}
      setTimeout(again, 100 * Math.min(tries, 5));
    };
    mine.onMessage.addListener((m: Told) => {
      ready = true;
      if (m && typeof m === 'object') {
        heard(m, (message) => {
          try {
            mine.postMessage(message);
          } catch {}
        });
      }
    });
    mine.onDisconnect.addListener(() => {
      if (port === mine) port = null;
    });
    again();
  };
}

export function defineProxy(shim: Shim): void {
  const onRequest = createEvent();
  const onError = createEvent();
  const onProxyError = createEvent();
  const settings = setting(shim, 'proxy.settings');
  putNamespace(shim, 'proxy', { settings, onRequest, onError, onProxyError });
  if (!shim.background || !asksFor(shim, 'proxy')) return;

  const connect = openPort(shim, (told, reply) => {
    if (told.route) void routeFor(told.route).then((choice) => reply({ routed: told.route!.n, choice }));
    if (told.ready || told.signIn) void signInNow(shim);
    if (told.change) fire(settings.onChange, told.change);
    if (told.error) {
      fire(onProxyError, told.error);
      // Firefox's proxy.onError takes an Error.
      fire(onError, new Error(told.error.error || 'Proxy error'));
    }
  });

  // A proxy set Chrome's way is signed into as Chrome would: the
  // extension's onAuthRequired listeners asked when the proxy asks.
  const set = settings.set;
  const after = () => {
    connect();
    void signInNow(shim);
  };
  settings.set = (...args: unknown[]) => {
    // Once the browser has it: with the callback, or as the promise settles.
    const last = args.length - 1;
    const callback = args[last];
    if (typeof callback === 'function') {
      args[last] = (...result: unknown[]) => {
        after();
        return callback(...result);
      };
      return set(...args);
    }
    const out = set(...args);
    void Promise.resolve(out).then(after, () => undefined);
    return out;
  };
  // A proxy it set before, which the browser put back at launch: the port
  // asks for its sign-in once it's open, and in case it never opens, asked
  // here too.
  connect();
  setTimeout(() => void signInNow(shim), 1500);

  /** What the browser was last told, as text; null before anything. */
  let told: string | null = null;
  let checking = false;
  let timer: ReturnType<typeof setInterval> | undefined;

  const check = async () => {
    // One at a time: the browser takes a moment to find out a proxy's sign-in.
    if (checking) return;
    checking = true;
    try {
      let choice: ProxyChoice | null = null;
      const page = await samplePage(shim);
      for (const listener of [...onRequest.listeners]) {
        choice = proxyChoice(
          await answerOf(listener, {
            requestId: String(nextRequest++),
            url: page.url,
            method: 'GET',
            frameId: 0,
            parentFrameId: -1,
            tabId: page.tabId,
            type: 'main_frame',
            timeStamp: Date.now(),
          }),
        );
        if (choice) break;
      }
      const text = JSON.stringify(choice);
      // Told when it changes, and once at the start, so a proxy left from
      // before is cleared.
      if (text === told) return;
      told = text;
      const asks = await shim.native('proxy.apply', [choice]).catch(() => null);
      // Once the browser holds it: a port from one holding none is closed.
      if (choice) connect();
      await signInTo(shim, asks);
    } finally {
      checking = false;
    }
  };

  /** The listeners' answer for a page at `url`, in the tab in front. */
  async function routeFor(ask: { url: string }): Promise<ProxyChoice | null> {
    const page = await samplePage(shim);
    for (const listener of [...onRequest.listeners]) {
      const choice = proxyChoice(
        await answerOf(listener, {
          requestId: String(nextRequest++),
          url: ask.url,
          method: 'GET',
          frameId: 0,
          parentFrameId: -1,
          tabId: page.tabId,
          type: 'main_frame',
          timeStamp: Date.now(),
        }),
      );
      if (choice) return choice;
    }
    return null;
  }

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
