import { describe, expect, it, vi } from 'vitest';

import { install } from '../src/dev-hooks';

describe('dev hooks', () => {
  it('keeps console messages and failed requests, and hides its log from enumeration', async () => {
    const log = install(window);
    console.warn('careful', { a: 1 });
    expect(log.console.at(-1)).toBe('[warn] careful {"a":1}');
    expect(Object.keys(window)).not.toContain('__moteDevLog');
    vi.spyOn(globalThis, 'fetch');
    expect(install(window)).toBe(log);
  });
});
