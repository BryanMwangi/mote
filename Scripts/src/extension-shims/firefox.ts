// A Firefox add-on is told it's in Firefox, as Chrome extensions are told
// they're in Chrome: runtime.getBrowserInfo(), which only Firefox has, and
// Firefox's navigator.userAgent, which add-ons read to choose their code
// (a VPN's proxy, set Firefox's way or Chrome's, takes neither in Safari's).
// `browser.menus` is filled for both (menus.ts).

import { fill } from './members';
import type { Shim } from './types';

/** Firefox's user agent on this Mac, at `version`. */
export function firefoxUserAgent(userAgent: string, version: string): string {
  const mac = /Mac OS X (\d+)[_.](\d+)/.exec(userAgent);
  const os = mac ? `${mac[1]}.${mac[2]}` : '10.15';
  return `Mozilla/5.0 (Macintosh; Intel Mac OS X ${os}; rv:${version}) Gecko/20100101 Firefox/${version}`;
}

export function presentAsFirefox(shim: Shim): void {
  if (!shim.config.firefox) return;
  const { root, inContent, worker, config } = shim;
  if (!inContent && typeof navigator !== 'undefined' && !/ Firefox\//.test(navigator.userAgent)) {
    const agent = firefoxUserAgent(navigator.userAgent, config.firefoxVersion);
    const proto =
      typeof root.WorkerNavigator !== 'undefined' && worker
        ? root.WorkerNavigator.prototype
        : typeof Navigator !== 'undefined'
          ? Navigator.prototype
          : null;
    try {
      if (proto) {
        Object.defineProperty(proto, 'userAgent', { get: () => agent, configurable: true });
        Object.defineProperty(proto, 'appVersion', { get: () => '5.0 (Macintosh)', configurable: true });
        Object.defineProperty(proto, 'vendor', { get: () => '', configurable: true });
      }
    } catch {}
  }
  fill(shim, 'runtime', {
    getBrowserInfo: () =>
      Promise.resolve({
        name: 'Firefox',
        vendor: 'Mozilla',
        version: shim.config.firefoxVersion,
        buildID: '20260101000000',
      }),
  });
}
