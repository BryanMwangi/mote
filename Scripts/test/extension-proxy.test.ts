import { describe, expect, it } from 'vitest';

import { firefoxUserAgent } from '../src/extension-shims/firefox';
import { proxyChoice } from '../src/extension-shims/proxy';

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
