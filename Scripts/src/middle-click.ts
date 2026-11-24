// Reports the link under a middle click to Swift (MiddleRelay in Tab.swift), which
// opens it in a new tab: WebKit delivers no navigation action for middle clicks.
// And keeps a page's own script off a link clicked with Shift or Option, which
// Mote opens as a preview or a split: a page that routes its links itself would
// otherwise go there too, underneath. Injected at document start into the main
// frame, in Mote's isolated content world.

import { isModifiedLinkClick, middleClickAddress } from './middle-click/link';

declare global {
  interface Window {
    __moteMiddle?: boolean;
  }
}

/** `MouseEvent.button` of the middle button. (In the `buttons` mask, 2 is the right button and 4 the middle.) */
const MIDDLE_BUTTON = 1;

if (!window.__moteMiddle) {
  window.__moteMiddle = true;
  // Bubbling phase, so a page that handles the click itself can prevent it; only
  // trusted events, so a synthetic auxclick can't open tabs.
  document.addEventListener('auxclick', (event) => {
    if (event.button !== MIDDLE_BUTTON || !event.isTrusted || event.defaultPrevented) return;
    const href = middleClickAddress(event.composedPath());
    if (href) window.webkit.messageHandlers.moteMiddle?.postMessage({ href });
  });
  // Capture on the window, first of all: the page's listeners never hear it,
  // and the link still follows (not prevented), for Mote to decide where.
  window.addEventListener(
    'click',
    (event) => {
      if (isModifiedLinkClick(event)) event.stopImmediatePropagation();
    },
    true,
  );
}
