import { beforeAll, describe, expect, it, vi } from 'vitest';

// What Mote answers, as NotificationRelay does, for one site allowed to notify.
const subscribed = {
  endpoint: 'https://push.example/wpush/v2/abc',
  p256dh: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  auth: 'BTBZMqHH6r4Tts7J_aSIgg',
  key: 'AQID',
};
const sent: Record<string, unknown>[] = [];
let held: typeof subscribed | null = null;

class Registration {
  constructor(readonly scope: string) {}
}

beforeAll(async () => {
  vi.stubGlobal('moteConfig', { handler: 'moteNotifications', clickEvent: 'mote-click' });
  vi.stubGlobal('ServiceWorkerRegistration', Registration);
  Object.defineProperty(window, 'webkit', {
    configurable: true,
    value: {
      messageHandlers: {
        moteNotifications: {
          postMessage: async (message: Record<string, unknown>) => {
            sent.push(message);
            switch (message.kind) {
              case 'state':
                return 'granted';
              case 'subscribe':
                held = subscribed;
                return held;
              case 'subscription':
                return held;
              case 'unsubscribe':
                held = null;
                return true;
              default:
                return null;
            }
          },
        },
      },
    },
  });
  await import('../src/notifications');
});

const manager = () =>
  (new Registration('https://example.com/scope/') as unknown as ServiceWorkerRegistration).pushManager;

describe('the Push API', () => {
  it('passes the checks push libraries make before subscribing', () => {
    expect('PushManager' in window).toBe(true);
    expect(Object.hasOwn(PushSubscription.prototype, 'getKey')).toBe(true);
    expect(Object.hasOwn(ServiceWorkerRegistration.prototype, 'showNotification')).toBe(true);
    expect(PushManager.supportedContentEncodings).toContain('aes128gcm');
  });

  it("subscribes with the site's server key, and hands back the endpoint and keys", async () => {
    const subscription = await manager().subscribe({
      userVisibleOnly: true,
      applicationServerKey: new Uint8Array([1, 2, 3]),
    });
    expect(sent.at(-1)).toEqual({ kind: 'subscribe', scope: 'https://example.com/scope/', key: 'AQID' });
    expect(subscription.endpoint).toBe(subscribed.endpoint);
    expect(new Uint8Array(subscription.getKey('p256dh') as ArrayBuffer)).toHaveLength(65);
    expect(new Uint8Array(subscription.getKey('auth') as ArrayBuffer)).toHaveLength(16);
    expect(subscription.toJSON()).toEqual({
      endpoint: subscribed.endpoint,
      expirationTime: null,
      keys: { p256dh: subscribed.p256dh, auth: subscribed.auth },
    });
    expect([...new Uint8Array(subscription.options.applicationServerKey as ArrayBuffer)]).toEqual([1, 2, 3]);
  });

  it('finds the subscription again, and lets it go', async () => {
    const found = await manager().getSubscription();
    expect(found?.endpoint).toBe(subscribed.endpoint);
    expect(await found?.unsubscribe()).toBe(true);
    expect(await manager().getSubscription()).toBeNull();
  });

  it('says how the site stands', async () => {
    expect(await manager().permissionState({ userVisibleOnly: true })).toBe('granted');
  });

  it('refuses when Mote does', async () => {
    held = null;
    const refusing = window.webkit!.messageHandlers.moteNotifications as unknown as {
      postMessage: (message: unknown) => Promise<unknown>;
    };
    const before = refusing.postMessage;
    refusing.postMessage = () => Promise.reject(new Error('NotAllowedError'));
    await expect(manager().subscribe({ userVisibleOnly: true })).rejects.toThrow(DOMException);
    refusing.postMessage = before;
  });
});
