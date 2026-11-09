// Generated from Scripts/src/media-session.ts by `pnpm build`. Do not edit.
(function() {

//#region src/lib/media.ts
/** Titles and names are cut to this many characters. */
	const LIMIT = 200;
	/**
	* Whether an element can be heard: not muted, not at zero volume, and, once
	* it has played a couple of seconds, with some audio decoded. Muted autoplay
	* backgrounds and GIF-like videos aren't.
	*/
	function audible(media) {
		if (media.muted || media.volume === 0) return false;
		const decoded = media.webkitAudioDecodedByteCount;
		return typeof decoded !== "number" || decoded > 0 || media.currentTime < 2;
	}
	/**
	* The element the strip controls: one playing that can be heard, else the
	* audible one furthest into its media (paused part way). Silent ones never.
	*/
	function currentMedia(root) {
		const all = [...root.querySelectorAll("video, audio")].filter(audible);
		return all.find((media) => !media.paused && !media.ended) ?? all.filter((media) => media.currentTime > 0 && !media.ended).toSorted((a, b) => b.currentTime - a.currentTime)[0] ?? null;
	}
	function clip(text) {
		return (text ?? "").trim().slice(0, 200);
	}
	/** The report for `media`, or null when there is nothing to control. */
	function describe(media, metadata, pageTitle, actions) {
		if (!media) return null;
		const handled = [...actions].toSorted();
		return {
			title: clip(metadata?.title) || clip(pageTitle),
			artist: clip(metadata?.artist),
			playing: !media.paused && !media.ended,
			actions: handled,
			session: Boolean(metadata?.title) || handled.length > 0
		};
	}

//#endregion
//#region src/media-session.ts
	const handler = window.webkit?.messageHandlers?.[moteConfig.handler];
	if (handler && !window.__moteMedia) {
		window.__moteMedia = true;
		const handlers = /* @__PURE__ */ new Map();
		const session = "mediaSession" in navigator ? navigator.mediaSession : null;
		if (session) {
			const set = session.setActionHandler.bind(session);
			session.setActionHandler = (action, act) => {
				if (act) handlers.set(action, act);
				else handlers.delete(action);
				set(action, act);
				soon();
			};
			const metadata = Object.getOwnPropertyDescriptor(MediaSession.prototype, "metadata");
			if (metadata?.set && metadata.get) {
				const { get, set: put } = metadata;
				Object.defineProperty(session, "metadata", {
					configurable: true,
					get: () => get.call(session),
					set: (value) => {
						put.call(session, value);
						soon();
					}
				});
			}
		}
		let sent = "";
		const report = () => {
			const media = currentMedia(document);
			const found = describe(media, session?.metadata, document.title, handlers.keys());
			const message = JSON.stringify(found);
			if (message === sent) return;
			sent = message;
			handler.postMessage(message);
		};
		let waiting;
		const soon = () => {
			clearTimeout(waiting);
			waiting = window.setTimeout(report, 150);
		};
		for (const kind of [
			"play",
			"pause",
			"ended",
			"emptied",
			"loadedmetadata",
			"volumechange"
		]) document.addEventListener(kind, soon, true);
		let shown = -1;
		let told = 0;
		const progress = () => {
			const media = currentMedia(document);
			if (!media || !Number.isFinite(media.duration) || media.duration <= 0) return;
			const now = Date.now();
			const done = Math.round(media.currentTime / media.duration * 1e3) / 1e3;
			if (done === shown || now - told < 1e3) return;
			shown = done;
			told = now;
			handler.postMessage(JSON.stringify({ progress: done }));
		};
		document.addEventListener("timeupdate", progress, true);
		document.addEventListener("seeked", () => {
			told = 0;
			progress();
		}, true);
		/** Runs the site's own handler for `action`, if it gave one. */
		const call = (action) => {
			const act = handlers.get(action);
			if (!act) return false;
			act({ action });
			return true;
		};
		const run = (command) => {
			const media = currentMedia(document);
			switch (command) {
				case "toggle":
					if (media && !media.paused) {
						if (!call("pause")) media.pause();
					} else if (!call("play")) media?.play().catch(() => {});
					break;
				case "next":
					call("nexttrack");
					break;
				case "previous": if (!call("previoustrack") && media) media.currentTime = 0;
			}
			soon();
		};
		window.addEventListener(moteConfig.commandEvent, (event) => {
			const command = event.detail;
			if (command === "toggle" || command === "next" || command === "previous") run(command);
		});
	}

//#endregion
})();