import { afterEach, describe, expect, it, vi } from 'vitest';

import { firefoxUserAgent } from '../src/extension-shims/firefox';
import { authListeners, defineProxy, proxyChoice, samplePage, signIn } from '../src/extension-shims/proxy';
import type { Shim } from '../src/extension-shims/types';

describe('extension proxies', () => {
  it('takes the first proxy of a list', () => {
    expect(
      proxyChoice([
        { type: 'https', host: 'a.example', port: 443 },
        { type: 'http', host: 'b.example', port: 80 },
      ]),
    ).toEqual({ type: 'https', host: 'a.example', port: 443 });
  });

  it('reads SOCKS, and a sign-in given with it', () => {
    expect(proxyChoice({ type: 'socks', host: 'h', port: '1080', username: 'u', password: 'p' })).toEqual({
      type: 'socks',
      host: 'h',
      port: 1080,
      username: 'u',
      password: 'p',
    });
    expect(
      proxyChoice({
        type: 'https',
        host: 'h',
        port: 443,
        proxyAuthorizationHeader: 'Basic ' + btoa('me:a:b'),
      }),
    ).toEqual({
      type: 'https',
      host: 'h',
      port: 443,
      username: 'me',
      password: 'a:b',
    });
  });

  it('is none for DIRECT, what it can not use, and nonsense', () => {
    expect(proxyChoice({ type: 'direct' })).toBeNull();
    expect(proxyChoice({ type: 'socks4', host: 'h', port: 1080 })).toBeNull();
    expect(proxyChoice({ type: 'http', host: '', port: 80 })).toBeNull();
    expect(proxyChoice({ type: 'http', host: 'h', port: 70_000 })).toBeNull();
    expect(proxyChoice(undefined)).toBeNull();
    expect(proxyChoice([])).toBeNull();
  });
});

describe('Firefox add-ons', () => {
  it("read Firefox's user agent, on this Mac", () => {
    const safari =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Safari/605.1.15';
    expect(firefoxUserAgent(safari, '140.0')).toBe(
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:140.0) Gecko/20100101 Firefox/140.0',
    );
  });
});

// Firefox's own cases (test_proxy_info_results.js), as Mote reads them: an
// answer Firefox refuses goes direct, as it does there.
describe("proxy answers, Firefox's cases", () => {
  it('refuses what Firefox refuses', () => {
    expect(proxyChoice(5)).toBeNull();
    expect(proxyChoice('INVALID')).toBeNull();
    expect(proxyChoice({ type: 'socks' })).toBeNull();
    expect(
      proxyChoice([
        { type: 'pptp', host: 'foo.bar', port: 1080 },
        { type: 'http', host: '192.168.1.1', port: 1128 },
      ]),
    ).toBeNull();
    expect(proxyChoice([{ type: 'http', host: 'foo.bar', port: 65_536 }])).toBeNull();
    expect(
      proxyChoice([{ type: 'socks', host: 'foo.bar', port: 3128, proxyAuthorizationHeader: 'test' }]),
    ).toBeNull();
    expect(proxyChoice({ type: 'http', host: 'foo bar', port: 80 })).toBeNull();
  });

  it('takes what Firefox takes', () => {
    expect(proxyChoice([{ type: 'direct' }])).toBeNull();
    expect(proxyChoice({ host: '1.2.3.4', port: '8080', type: 'http' })).toEqual({
      type: 'http',
      host: '1.2.3.4',
      port: 8080,
    });
    expect(proxyChoice({ host: '1.2.3.4', port: 8080, type: 'PROXY' })).toEqual({
      type: 'http',
      host: '1.2.3.4',
      port: 8080,
    });
    expect(
      proxyChoice([{ type: 'https', host: 'foo.bar', port: 3128, connectionIsolationKey: 'key' }]),
    ).toEqual({
      type: 'https',
      host: 'foo.bar',
      port: 3128,
    });
    expect(
      proxyChoice([
        {
          type: 'socks',
          host: 'foo.bar',
          port: 1080,
          username: 'johnsmith',
          password: 'pass123',
          proxyDNS: true,
          failoverTimeout: 3,
        },
        { type: 'http', host: '192.168.1.1', port: 3128 },
      ]),
    ).toEqual({ type: 'socks', host: 'foo.bar', port: 1080, username: 'johnsmith', password: 'pass123' });
  });
});

// Chrome's proxy sign-in (webRequest.onAuthRequired with isProxy), as
// web_request_apitest's proxy cases ask it: each 407 a request of its own.
describe('proxy sign-ins', () => {
  afterEach(() => authListeners.clear());

  it('asks each time as a new request, with the realm the proxy gave', async () => {
    const answered = new Set<string>();
    const seen: Record<string, unknown>[] = [];
    // A listener that takes a repeated request for its sign-in failing.
    authListeners.add((details: Record<string, unknown>) => {
      seen.push(details);
      const id = String(details.requestId);
      if (answered.has(id)) return { cancel: true };
      answered.add(id);
      return { authCredentials: { username: 'u', password: 'p' } };
    });
    const asked = { host: 'vpn.example', port: '443', type: 'https', scheme: 'basic', realm: 'VPN' };
    const given = { host: 'vpn.example', port: 443, username: 'u', password: 'p' };
    expect(await signIn(asked)).toEqual(given);
    expect(await signIn(asked)).toEqual(given);
    expect(seen[0]?.requestId).not.toBe(seen[1]?.requestId);
    expect(seen[0]).toMatchObject({
      isProxy: true,
      realm: 'VPN',
      statusCode: 407,
      challenger: { host: 'vpn.example', port: 443 },
      proxyInfo: { host: 'vpn.example', port: 443, type: 'https' },
    });
  });

  it("takes an asyncBlocking listener's callback, and goes on past one with nothing", async () => {
    authListeners.add(() => undefined);
    authListeners.add((_d: unknown, callback: (r: unknown) => void) => {
      setTimeout(() => callback({ authCredentials: { username: 'a', password: 'b' } }), 5);
    });
    expect(await signIn({ host: 'h', port: 8080 })).toEqual({
      host: 'h',
      port: 8080,
      username: 'a',
      password: 'b',
    });
  });

  it('is null when no listener gives one', async () => {
    authListeners.add(() => ({ cancel: true }));
    expect(await signIn({ host: 'h', port: 1 })).toBeNull();
  });
});

/** A background with the proxy permission, its native calls and its port to the browser. */
function proxyBackground(answers: Record<string, unknown> = {}) {
  const listeners: { message: ((m: unknown) => void)[]; disconnect: (() => void)[] } = {
    message: [],
    disconnect: [],
  };
  const posted: unknown[] = [];
  const port = {
    postMessage: (m: unknown) => posted.push(m),
    onMessage: { addListener: (f: (m: unknown) => void) => listeners.message.push(f) },
    onDisconnect: { addListener: (f: () => void) => listeners.disconnect.push(f) },
  };
  const runtime = {
    id: 'abc',
    getManifest: () => ({ permissions: ['proxy'] }),
    connectNative: vi.fn(() => port),
  };
  const chrome: Record<string, any> = { runtime };
  const native = vi.fn((api: string, _args: unknown[]) => Promise.resolve(answers[api] ?? null));
  const shim = {
    root: {},
    chrome,
    runtime,
    background: true,
    put: (target: Record<string, unknown>, key: string, value: unknown) => {
      target[key] = value;
    },
    native,
  } as unknown as Shim;
  defineProxy(shim);
  const tell = (m: unknown) => listeners.message.forEach((f) => f(m));
  return { chrome, runtime, native, posted, tell };
}

// proxy_apitest's events cases: what the browser says reaches the extension.
describe('what the browser tells a proxy extension', () => {
  afterEach(() => {
    authListeners.clear();
    vi.useRealTimers();
  });

  it('opens its port and greets the browser', () => {
    vi.useFakeTimers();
    const { runtime, posted } = proxyBackground();
    expect(runtime.connectNative).toHaveBeenCalledWith('mote.proxy');
    expect(posted[0]).toEqual({ hello: true });
  });

  it("fires settings.onChange and onProxyError, and Firefox's onError with an Error", () => {
    vi.useFakeTimers();
    const { chrome, tell } = proxyBackground();
    const changes: unknown[] = [];
    const errors: unknown[] = [];
    const firefoxErrors: unknown[] = [];
    chrome.proxy.settings.onChange.addListener((d: unknown) => changes.push(d));
    chrome.proxy.onProxyError.addListener((d: unknown) => errors.push(d));
    chrome.proxy.onError.addListener((e: unknown) => firefoxErrors.push(e));
    const change = { value: { mode: 'system' }, levelOfControl: 'controlled_by_other_extensions' };
    tell({ change });
    tell({ error: { fatal: true, error: 'net::ERR_PROXY_CONNECTION_FAILED', details: '' } });
    expect(changes).toEqual([change]);
    expect(errors).toEqual([{ fatal: true, error: 'net::ERR_PROXY_CONNECTION_FAILED', details: '' }]);
    expect(firefoxErrors[0]).toBeInstanceOf(Error);
    expect((firefoxErrors[0] as Error).message).toBe('net::ERR_PROXY_CONNECTION_FAILED');
  });

  it('signs in when the browser asks, giving what its listeners gave', async () => {
    vi.useFakeTimers();
    const asks = [{ host: 'vpn.example', port: '443', scheme: 'basic', realm: '' }];
    const { native, tell } = proxyBackground({ 'proxy.challenge': asks });
    authListeners.add(() => ({ authCredentials: { username: 'u', password: 'p' } }));
    tell({ signIn: true });
    await vi.runAllTimersAsync();
    expect(native).toHaveBeenCalledWith('proxy.credentials', [
      [{ host: 'vpn.example', port: 443, username: 'u', password: 'p' }],
    ]);
  });
});

// Firefox asks proxy.onRequest about a tab's request with that tab's id.
/** A shim whose tabs.query answers `tabs`. */
const withTabs = (tabs: unknown[]) => ({ chrome: { tabs: { query: async () => tabs } } }) as unknown as Shim;

describe('the page a proxy listener is asked about', () => {
  it('is the tab in front, with its id, else the sample page', async () => {
    const shim = withTabs;
    expect(await samplePage(shim([{ id: 7, url: 'https://news.example/' }]))).toEqual({
      url: 'https://news.example/',
      tabId: 7,
    });
    expect(await samplePage(shim([{ id: 8, url: 'about:blank' }]))).toEqual({
      url: 'https://www.example.com/',
      tabId: -1,
    });
  });
});
