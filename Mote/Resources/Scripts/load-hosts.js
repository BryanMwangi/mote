// Generated from Scripts/src/load-hosts.ts by `pnpm build`. Do not edit.
(function() {

//#region src/load-hosts.ts
/** The window, with the mark set once the script runs in this document. */
	const marked = window;
	const handler = window.webkit?.messageHandlers?.[moteConfig.handler];
	if (handler && !marked.__moteLoadHosts && "PerformanceObserver" in window) {
		marked.__moteLoadHosts = true;
		let last = "";
		let done = false;
		let waiting;
		let next = "";
		const send = () => {
			waiting = void 0;
			if (next === last) return;
			last = next;
			handler.postMessage(next);
		};
		/** At most ten times a second. */
		const note = (host) => {
			if (done) return;
			next = host;
			waiting ??= window.setTimeout(send, 100);
		};
		const observer = new PerformanceObserver((list) => {
			const entry = list.getEntries().at(-1);
			if (!entry) return;
			try {
				note(new URL(entry.name).host);
			} catch {}
		});
		try {
			observer.observe({
				type: "resource",
				buffered: true
			});
		} catch {
			observer.observe({ entryTypes: ["resource"] });
		}
		window.addEventListener("load", () => {
			done = true;
			observer.disconnect();
			clearTimeout(waiting);
			next = "";
			send();
		}, { once: true });
	}

//#endregion
})();