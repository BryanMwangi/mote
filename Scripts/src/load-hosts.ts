// Tells Mote which site the page is loading from while it loads, for the
// status at the foot of the page ("Loading from cdn.example.com…"), as other
// browsers show it. Swift: LoadRelay in StatusLine.swift.
//
// Injected at document start into the main frame, in Mote's isolated world.
// Only hosts are sent, and only until the page has loaded.

declare const moteConfig: { handler: string };

/** The window, with the mark set once the script runs in this document. */
const marked = window as Window & { __moteLoadHosts?: boolean };
const handler = window.webkit?.messageHandlers?.[moteConfig.handler];

if (handler && !marked.__moteLoadHosts && 'PerformanceObserver' in window) {
  marked.__moteLoadHosts = true;
  let last = '';
  let done = false;
  let waiting: number | undefined;
  let next = '';

  const send = (): void => {
    waiting = undefined;
    if (next === last) return;
    last = next;
    // A WebKit message handler, not window.postMessage: there is no target origin.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    handler.postMessage(next);
  };

  /** At most ten times a second. */
  const note = (host: string): void => {
    if (done) return;
    next = host;
    waiting ??= window.setTimeout(send, 100);
  };

  const observer = new PerformanceObserver((list) => {
    const entry = list.getEntries().at(-1);
    if (!entry) return;
    try {
      note(new URL(entry.name).host);
    } catch {
      // Not an address: nothing to show.
    }
  });
  try {
    observer.observe({ type: 'resource', buffered: true });
  } catch {
    // Older engines take entryTypes only.
    observer.observe({ entryTypes: ['resource'] });
  }

  window.addEventListener(
    'load',
    () => {
      done = true;
      observer.disconnect();
      clearTimeout(waiting);
      next = '';
      send();
    },
    { once: true },
  );
}
