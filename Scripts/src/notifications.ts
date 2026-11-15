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
    /** What a site was told, set by Mote just before this script: its host and the answer. */
    __moteNotify?: [string, NotificationPermission];
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

/** Base64url, as push keys travel. */
const encode = (bytes: Uint8Array): string =>
  btoa(String.fromCodePoint(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replace(/=+$/, '');
const decode = (text: string): Uint8Array =>
  Uint8Array.from(atob(text.replaceAll('-', '+').replaceAll('_', '/')), (c) => c.codePointAt(0) ?? 0);
const keyText = (key: BufferSource | string | null | undefined): string => {
  if (key == null) return '';
  if (typeof key === 'string') return key;
  return encode(
    key instanceof ArrayBuffer
      ? new Uint8Array(key)
      : new Uint8Array(key.buffer, key.byteOffset, key.byteLength),
  );
};

if (handler && !window.__moteNotifications) {
  window.__moteNotifications = true;
  const send = (message: Record<string, unknown>): Promise<unknown> =>
    // A WebKit message handler, not window.postMessage: there is no target origin.
    // oxlint-disable-next-line unicorn/require-post-message-target-origin
    handler.postMessage(message).catch(() => undefined);

  // Known at once, for the site Mote armed this document for: sites read
  // `Notification.permission` as they load, before any answer could come.
  const told = window.__moteNotify;
  delete window.__moteNotify;
  let permission: NotificationPermission = told?.[0] === location.hostname ? told[1] : 'default';
  const known = send({ kind: 'state' }).then((answer) => {
    if (answer === 'granted' || answer === 'denied' || answer === 'default') permission = answer;
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

  // The Push API, which WebKit doesn't give apps: Mote keeps a registration's
  // subscription on a Web Push server and shows what the site pushes
  // (WebPushService.swift). Only for a site allowed to notify.
  if (typeof ServiceWorkerRegistration !== 'undefined' && !('PushManager' in window)) {
    interface Subscribed {
      endpoint: string;
      p256dh: string;
      auth: string;
      key: string;
    }
    class MotePushSubscription {
      readonly endpoint: string;
      readonly expirationTime = null;
      readonly options: { userVisibleOnly: boolean; applicationServerKey: ArrayBuffer | null };
      readonly #scope: string;
      readonly #keys: { p256dh: string; auth: string };

      constructor(scope: string, made: Subscribed) {
        this.#scope = scope;
        this.endpoint = made.endpoint;
        this.#keys = { p256dh: made.p256dh, auth: made.auth };
        this.options = {
          userVisibleOnly: true,
          applicationServerKey: made.key ? (decode(made.key).buffer as ArrayBuffer) : null,
        };
      }

      getKey(name: PushEncryptionKeyName): ArrayBuffer | null {
        const key = this.#keys[name];
        return key ? (decode(key).buffer as ArrayBuffer) : null;
      }

      toJSON(): PushSubscriptionJSON {
        return { endpoint: this.endpoint, expirationTime: null, keys: { ...this.#keys } };
      }

      unsubscribe(): Promise<boolean> {
        return send({ kind: 'unsubscribe', scope: this.#scope }).then((answer) => answer === true);
      }
    }

    class MotePushManager {
      static get supportedContentEncodings(): readonly string[] {
        return ['aes128gcm'];
      }

      readonly #scope: string;

      constructor(scope: string) {
        this.#scope = scope;
      }

      async subscribe(options: PushSubscriptionOptionsInit = {}): Promise<MotePushSubscription> {
        const made = (await send({
          kind: 'subscribe',
          scope: this.#scope,
          key: keyText(options.applicationServerKey),
        })) as Subscribed | null | undefined;
        if (!made) throw new DOMException('Notifications are not allowed for this site.', 'NotAllowedError');
        return new MotePushSubscription(this.#scope, made);
      }

      async getSubscription(): Promise<MotePushSubscription | null> {
        const made = (await send({ kind: 'subscription', scope: this.#scope })) as
          | Subscribed
          | null
          | undefined;
        return made ? new MotePushSubscription(this.#scope, made) : null;
      }

      async permissionState(): Promise<PermissionState> {
        await known;
        return permission === 'default' ? 'prompt' : permission;
      }
    }

    const managers = new Map<string, MotePushManager>();
    Object.defineProperty(ServiceWorkerRegistration.prototype, 'pushManager', {
      get(this: ServiceWorkerRegistration) {
        let manager = managers.get(this.scope);
        if (!manager) {
          manager = new MotePushManager(this.scope);
          managers.set(this.scope, manager);
        }
        return manager;
      },
      configurable: true,
    });
    for (const [name, value] of [
      ['PushManager', MotePushManager],
      ['PushSubscription', MotePushSubscription],
    ] as const) {
      Object.defineProperty(window, name, { value, writable: true, configurable: true });
    }
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
