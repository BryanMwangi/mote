// Generated from Scripts/src/notifications.ts by `pnpm build`. Do not edit.
(function() {

//#region src/notifications.ts
	const handler = window.webkit?.messageHandlers?.[moteConfig.handler];
	/** What Mote is told of a notification, by either way of showing one. */
	const describe = (id, title, options) => ({
		kind: "show",
		id,
		title: String(title),
		body: String(options.body ?? ""),
		tag: String(options.tag ?? ""),
		silent: options.silent === true
	});
	/** Base64url, as push keys travel. */
	const encode = (bytes) => btoa(String.fromCodePoint(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
	const decode = (text) => Uint8Array.from(atob(text.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.codePointAt(0) ?? 0);
	const keyText = (key) => {
		if (key == null) return "";
		if (typeof key === "string") return key;
		return encode(key instanceof ArrayBuffer ? new Uint8Array(key) : new Uint8Array(key.buffer, key.byteOffset, key.byteLength));
	};
	if (handler && !window.__moteNotifications) {
		window.__moteNotifications = true;
		const send = (message) => handler.postMessage(message).catch(() => void 0);
		const told = window.__moteNotify;
		delete window.__moteNotify;
		let permission = told?.[0] === location.hostname ? told[1] : "default";
		const known = send({ kind: "state" }).then((answer) => {
			if (answer === "granted" || answer === "denied" || answer === "default") permission = answer;
		});
		const showing = /* @__PURE__ */ new Map();
		const show = async (id, title, options) => {
			await known;
			return permission === "granted" && await send(describe(id, title, options)) === true;
		};
		class MoteNotification extends EventTarget {
			static get permission() {
				return permission;
			}
			static get maxActions() {
				return 0;
			}
			static requestPermission(callback) {
				return send({ kind: "ask" }).then((answer) => {
					if (answer === "granted" || answer === "denied") permission = answer;
					callback?.(permission);
					return permission;
				});
			}
			title;
			body;
			tag;
			icon;
			data;
			dir;
			lang;
			silent;
			requireInteraction;
			onclick = null;
			onshow = null;
			onclose = null;
			onerror = null;
			#id = crypto.randomUUID();
			constructor(title, options = {}) {
				super();
				if (arguments.length === 0) throw new TypeError("Failed to construct 'Notification': 1 argument required.");
				this.title = String(title);
				this.body = String(options.body ?? "");
				this.tag = String(options.tag ?? "");
				this.icon = String(options.icon ?? "");
				this.data = options.data ?? null;
				this.dir = options.dir ?? "auto";
				this.lang = options.lang ?? "";
				this.silent = options.silent === true;
				this.requireInteraction = options.requireInteraction === true;
				show(this.#id, title, options).then((shown) => {
					if (shown) showing.set(this.#id, this);
					this.fire(shown ? "show" : "error");
				});
			}
			close() {
				if (!showing.delete(this.#id)) return;
				send({
					kind: "close",
					id: this.#id
				});
				this.fire("close");
			}
			/** Mote's word that this one was clicked. */
			clicked() {
				this.fire("click");
			}
			fire(type) {
				const event = new Event(type, { cancelable: type === "click" });
				const own = this[`on${type}`];
				if (typeof own === "function") own.call(this, event);
				this.dispatchEvent(event);
			}
		}
		window.addEventListener(moteConfig.clickEvent, (event) => {
			const id = event.detail;
			if (typeof id === "string") showing.get(id)?.clicked();
		});
		Object.defineProperty(window, "Notification", {
			value: MoteNotification,
			writable: true,
			configurable: true
		});
		const permissions = navigator.permissions;
		const query = permissions?.query?.bind(permissions);
		if (query) permissions.query = async (descriptor) => {
			if (descriptor?.name !== "notifications") return query(descriptor);
			await known;
			const status = new EventTarget();
			Object.defineProperties(status, {
				state: { value: permission === "default" ? "prompt" : permission },
				name: { value: "notifications" }
			});
			status.onchange = null;
			return status;
		};
		if (typeof ServiceWorkerRegistration !== "undefined" && !("PushManager" in window)) {
			class MotePushSubscription {
				endpoint;
				expirationTime = null;
				options;
				#scope;
				#keys;
				constructor(scope, made) {
					this.#scope = scope;
					this.endpoint = made.endpoint;
					this.#keys = {
						p256dh: made.p256dh,
						auth: made.auth
					};
					this.options = {
						userVisibleOnly: true,
						applicationServerKey: made.key ? decode(made.key).buffer : null
					};
				}
				getKey(name) {
					const key = this.#keys[name];
					return key ? decode(key).buffer : null;
				}
				toJSON() {
					return {
						endpoint: this.endpoint,
						expirationTime: null,
						keys: { ...this.#keys }
					};
				}
				unsubscribe() {
					return send({
						kind: "unsubscribe",
						scope: this.#scope
					}).then((answer) => answer === true);
				}
			}
			class MotePushManager {
				static get supportedContentEncodings() {
					return ["aes128gcm"];
				}
				#scope;
				constructor(scope) {
					this.#scope = scope;
				}
				async subscribe(options = {}) {
					const made = await send({
						kind: "subscribe",
						scope: this.#scope,
						key: keyText(options.applicationServerKey)
					});
					if (!made) throw new DOMException("Notifications are not allowed for this site.", "NotAllowedError");
					return new MotePushSubscription(this.#scope, made);
				}
				async getSubscription() {
					const made = await send({
						kind: "subscription",
						scope: this.#scope
					});
					return made ? new MotePushSubscription(this.#scope, made) : null;
				}
				async permissionState() {
					await known;
					return permission === "default" ? "prompt" : permission;
				}
			}
			const managers = /* @__PURE__ */ new Map();
			Object.defineProperty(ServiceWorkerRegistration.prototype, "pushManager", {
				get() {
					let manager = managers.get(this.scope);
					if (!manager) {
						manager = new MotePushManager(this.scope);
						managers.set(this.scope, manager);
					}
					return manager;
				},
				configurable: true
			});
			for (const [name, value] of [["PushManager", MotePushManager], ["PushSubscription", MotePushSubscription]]) Object.defineProperty(window, name, {
				value,
				writable: true,
				configurable: true
			});
		}
		if (typeof ServiceWorkerRegistration !== "undefined") {
			ServiceWorkerRegistration.prototype.showNotification = async function(title, options = {}) {
				if (!await show(crypto.randomUUID(), title, options)) throw new TypeError("No permission to show notifications.");
			};
			ServiceWorkerRegistration.prototype.getNotifications = async () => [];
		}
	}

//#endregion
})();