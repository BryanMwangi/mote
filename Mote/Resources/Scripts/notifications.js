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
	if (handler && !window.__moteNotifications) {
		window.__moteNotifications = true;
		const send = (message) => handler.postMessage(message).catch(() => void 0);
		let permission = "default";
		const known = send({ kind: "state" }).then((answer) => {
			if (answer === "granted" || answer === "denied") permission = answer;
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
		if (typeof ServiceWorkerRegistration !== "undefined") {
			ServiceWorkerRegistration.prototype.showNotification = async function(title, options = {}) {
				if (!await show(crypto.randomUUID(), title, options)) throw new TypeError("No permission to show notifications.");
			};
			ServiceWorkerRegistration.prototype.getNotifications = async () => [];
		}
	}

//#endregion
})();