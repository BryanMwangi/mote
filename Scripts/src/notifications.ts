// The page side of web notifications (WebNotifications.swift). WebKit gives
// apps no way to show a page's notifications, so this stands in for
// `Notification`, `navigator.permissions.query` for notifications, and a
// service worker registration's `showNotification`, and asks Mote, which
// shows them as macOS notifications.
//
// Injected at document start into the main frame in the page's own world,
// where the page's scripts find it. Mote answers through a message handler
// with replies, and tells of a click as a window event whose name it draws at
// launch. A page can only ever show notifications as itself.

declare const moteConfig: { handler: string; clickEvent: string };

interface Replying {
  postMessage(message: unknown): Promise<unknown>;
}

declare global {
  interface Window {
    /** Set once the script runs in this document. */
    __moteNotifications?: boolean;
  }
}

const handler = window.webkit?.messageHandlers?.[moteConfig.handler] as Replying | undefined;

/** What Mote is told of a notification, by either way of showing one. */
const describe = (id: string, title: string, options: NotificationOptions): Record<string, unknown> => ({
  kind: 'show',
  id,
  title: String(title),
  body: String(options.body ?? ''),
  tag: String(options.tag ?? ''),
  silent: options.silent === true,
});

if (handler && !window.__moteNotifications) {
  window.__moteNotifications = true;
  const send = (message: Record<string, unknown>): Promise<unknown> =>
    // A WebKit message handler, not window.postMessage: there is no target origin.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    handler.postMessage(message).catch(() => undefined);

  let permission: NotificationPermission = 'default';
  const known = send({ kind: 'state' }).then((answer) => {
    if (answer === 'granted' || answer === 'denied') permission = answer;
  });
  const showing = new Map<string, MoteNotification>();

  const show = async (id: string, title: string, options: NotificationOptions): Promise<boolean> => {
    await known;
    return permission === 'granted' && (await send(describe(id, title, options))) === true;
  };

  class MoteNotification extends EventTarget {
    static get permission(): NotificationPermission {
      return permission;
    }

    static get maxActions(): number {
      return 0;
    }

    static requestPermission(callback?: NotificationPermissionCallback): Promise<NotificationPermission> {
      return send({ kind: 'ask' }).then((answer) => {
        if (answer === 'granted' || answer === 'denied') permission = answer;
        callback?.(permission);
        return permission;
      });
    }

    readonly title: string;
    readonly body: string;
    readonly tag: string;
    readonly icon: string;
    readonly data: unknown;
    readonly dir: NotificationDirection;
    readonly lang: string;
    readonly silent: boolean;
    readonly requireInteraction: boolean;
    onclick: ((this: Notification, event: Event) => unknown) | null = null;
    onshow: ((this: Notification, event: Event) => unknown) | null = null;
    onclose: ((this: Notification, event: Event) => unknown) | null = null;
    onerror: ((this: Notification, event: Event) => unknown) | null = null;
    readonly #id = crypto.randomUUID();

    constructor(title: string, options: NotificationOptions = {}) {
      super();
      if (arguments.length === 0)
        throw new TypeError("Failed to construct 'Notification': 1 argument required.");
      this.title = String(title);
      this.body = String(options.body ?? '');
      this.tag = String(options.tag ?? '');
      this.icon = String(options.icon ?? '');
      this.data = options.data ?? null;
      this.dir = options.dir ?? 'auto';
      this.lang = options.lang ?? '';
      this.silent = options.silent === true;
      this.requireInteraction = options.requireInteraction === true;
      void show(this.#id, title, options).then((shown) => {
        if (shown) showing.set(this.#id, this);
        this.fire(shown ? 'show' : 'error');
      });
    }

    close(): void {
      if (!showing.delete(this.#id)) return;
      void send({ kind: 'close', id: this.#id });
      this.fire('close');
    }

    /** Mote's word that this one was clicked. */
    clicked(): void {
      this.fire('click');
    }

    private fire(type: 'click' | 'show' | 'close' | 'error'): void {
      const event = new Event(type, { cancelable: type === 'click' });
      const own = this[`on${type}`];
      if (typeof own === 'function') own.call(this as unknown as Notification, event);
      this.dispatchEvent(event);
    }
  }

  window.addEventListener(moteConfig.clickEvent, (event) => {
    const id = (event as CustomEvent<unknown>).detail;
    if (typeof id === 'string') showing.get(id)?.clicked();
  });

  Object.defineProperty(window, 'Notification', {
    value: MoteNotification,
    writable: true,
    configurable: true,
  });

  // A site asks how it stands before asking at all.
  const permissions = navigator.permissions;
  const query = permissions?.query?.bind(permissions);
  if (query) {
    permissions.query = async (descriptor: PermissionDescriptor): Promise<PermissionStatus> => {
      if (descriptor?.name !== 'notifications') return query(descriptor);
      await known;
      const status = new EventTarget() as PermissionStatus & { onchange: null };
      const state: PermissionState = permission === 'default' ? 'prompt' : permission;
      Object.defineProperties(status, { state: { value: state }, name: { value: 'notifications' } });
      // oxlint-disable-next-line unicorn/prefer-add-event-listener -- the property itself, as a status has it
      status.onchange = null;
      return status;
    };
  }

  // A site's service worker shows them for it; the page asks it to.
  if (typeof ServiceWorkerRegistration !== 'undefined') {
    ServiceWorkerRegistration.prototype.showNotification = async function (
      title: string,
      options: NotificationOptions = {},
    ): Promise<void> {
      if (!(await show(crypto.randomUUID(), title, options))) {
        throw new TypeError('No permission to show notifications.');
      }
    };
    ServiceWorkerRegistration.prototype.getNotifications = async () => [];
  }
}

// A module, so its declarations stay its own.
// oxlint-disable-next-line unicorn/require-module-specifiers
export {};
