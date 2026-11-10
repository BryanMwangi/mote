// The page side of the media strip at the foot of the sidebar (MediaSession.swift):
// reports what the page is playing, and runs the strip's buttons.
//
// Injected at document start into the main frame in the page's own world, as
// only there can it see the handlers a site gives `navigator.mediaSession`
// (next and previous track, mostly). Swift sends commands as a window event
// whose name it draws at launch; a page can fake reports for its own tab, and
// nothing more.

import { currentMedia, describe } from './lib/media';

/** The message handler's name and the command event's. */
declare const moteConfig: { handler: string; commandEvent: string };

type Command = 'toggle' | 'next' | 'previous';

declare global {
  interface Window {
    /** Set once the script runs in this document. */
    __moteMedia?: boolean;
  }
}

const handler = window.webkit?.messageHandlers?.[moteConfig.handler];

if (handler && !window.__moteMedia) {
  window.__moteMedia = true;
  const handlers = new Map<string, MediaSessionActionHandler>();
  const session = 'mediaSession' in navigator ? navigator.mediaSession : null;

  if (session) {
    const set = session.setActionHandler.bind(session);
    session.setActionHandler = (action: MediaSessionAction, act: MediaSessionActionHandler | null): void => {
      if (act) handlers.set(action, act);
      else handlers.delete(action);
      set(action, act);
      soon();
    };
    // A new track without a media event (one element, the source swapped
    // under it) still sets new metadata: hear that, as Firefox does, rather
    // than looking again every few seconds.
    const metadata = Object.getOwnPropertyDescriptor(MediaSession.prototype, 'metadata');
    if (metadata?.set && metadata.get) {
      const { get, set: put } = metadata;
      Object.defineProperty(session, 'metadata', {
        configurable: true,
        get: () => get.call(session),
        set: (value: MediaMetadata | null) => {
          put.call(session, value);
          soon();
        },
      });
    }
  }

  let sent = '';
  const report = (): void => {
    const media = currentMedia(document);
    const found = describe(media, session?.metadata, document.title, handlers.keys());
    const message = JSON.stringify(found);
    if (message === sent) return;
    sent = message;
    // A WebKit message handler, not window.postMessage: there is no target origin.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    handler.postMessage(message);
  };

  let waiting: number | undefined;
  const soon = (): void => {
    clearTimeout(waiting);
    waiting = window.setTimeout(report, 150);
  };

  // Media events don't bubble, so they're caught on the way down.
  for (const kind of ['play', 'pause', 'ended', 'emptied', 'loadedmetadata', 'volumechange']) {
    document.addEventListener(kind, soon, true);
  }

  // How far it has played, for the strip's fill: apart from the report, and
  // at most once a second, so the strip itself isn't redrawn as it plays.
  let shown = -1;
  let told = 0;
  const progress = (): void => {
    const media = currentMedia(document);
    if (!media || !Number.isFinite(media.duration) || media.duration <= 0) return;
    const now = Date.now();
    const done = Math.round((media.currentTime / media.duration) * 1000) / 1000;
    if (done === shown || now - told < 1000) return;
    shown = done;
    told = now;
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    handler.postMessage(JSON.stringify({ progress: done }));
  };
  document.addEventListener('timeupdate', progress, true);
  document.addEventListener('seeked', () => {
    told = 0;
    progress();
  }, true);

  /** Runs the site's own handler for `action`, if it gave one. */
  const call = (action: MediaSessionAction): boolean => {
    const act = handlers.get(action);
    if (!act) return false;
    act({ action });
    return true;
  };

  const run = (command: Command): void => {
    const media = currentMedia(document);
    switch (command) {
      case 'toggle':
        if (media && !media.paused) {
          if (!call('pause')) media.pause();
        } else if (!call('play')) {
          void media?.play().catch(() => {});
        }
        break;
      case 'next':
        // With no next track, ten seconds on.
        if (!call('nexttrack') && media) media.currentTime = Math.min(media.duration || Infinity, media.currentTime + 10);
        break;
      case 'previous':
        if (!call('previoustrack') && media) media.currentTime = 0;
        break;
    }
    soon();
  };

  window.addEventListener(moteConfig.commandEvent, (event) => {
    const command = (event as CustomEvent<unknown>).detail;
    if (command === 'toggle' || command === 'next' || command === 'previous') run(command);
  });
}
