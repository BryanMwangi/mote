import { describe, expect, it } from 'vitest';
import { isModifiedLinkClick, middleClickAddress } from '../src/middle-click/link';

function pathTo(html: string, selector: string): EventTarget[] {
  document.body.innerHTML = html;
  const path: EventTarget[] = [];
  for (let node: Element | null = document.querySelector(selector); node; node = node.parentElement)
    path.push(node);
  return [...path, document, window];
}

describe('middleClickAddress', () => {
  it('finds the link around the clicked element', () => {
    expect(middleClickAddress(pathTo('<a href="https://example.com/page"><b id="t">Go</b></a>', '#t'))).toBe(
      'https://example.com/page',
    );
  });

  it('treats an image map area as a link', () => {
    expect(middleClickAddress(pathTo('<map><area id="t" href="https://example.com/area"></map>', '#t'))).toBe(
      'https://example.com/area',
    );
  });

  it('skips anchors without an address and is null outside links', () => {
    expect(
      middleClickAddress(pathTo('<a href="https://example.com/outer"><a id="t" name="x">In</a></a>', '#t')),
    ).toBeNull();
    expect(middleClickAddress(pathTo('<p id="t">Text</p>', '#t'))).toBeNull();
  });
});

/** A trusted left click on `#t` in `html`, with these keys. */
const click = (keys: Partial<MouseEvent>, html = '<a href="https://example.com/"><b id="t">Go</b></a>') =>
  isModifiedLinkClick({
    isTrusted: true,
    button: 0,
    shiftKey: false,
    altKey: false,
    metaKey: false,
    ctrlKey: false,
    composedPath: () => pathTo(html, '#t'),
    ...keys,
  } as MouseEvent);

describe('isModifiedLinkClick', () => {
  it('is a Shift or Option click on a web link', () => {
    expect(click({ altKey: true })).toBe(true);
    expect(click({ shiftKey: true })).toBe(true);
  });

  it('leaves plain, Command and Control clicks, untrusted ones, and links that are not web pages', () => {
    expect(click({})).toBe(false);
    expect(click({ altKey: true, metaKey: true })).toBe(false);
    expect(click({ shiftKey: true, ctrlKey: true })).toBe(false);
    expect(click({ altKey: true, isTrusted: false })).toBe(false);
    expect(click({ altKey: true }, '<a href="mailto:a@b.c"><b id="t">Mail</b></a>')).toBe(false);
    expect(click({ altKey: true }, '<span><b id="t">Text</b></span>')).toBe(false);
  });
});
