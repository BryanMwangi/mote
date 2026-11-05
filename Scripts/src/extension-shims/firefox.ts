// A Firefox add-on is told it's in Firefox, as Chrome extensions are told
// they're in Chrome: runtime.getBrowserInfo(), which only Firefox has and
// add-ons ask to choose their code. `browser.menus` is filled for both
// (menus.ts).

import { fill } from './members';
import type { Shim } from './types';

export function presentAsFirefox(shim: Shim): void {
  if (!shim.config.firefox) return;
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
