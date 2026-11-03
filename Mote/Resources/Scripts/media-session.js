// Generated from Scripts/src/media-session.ts by `pnpm build`. Do not edit.
(function() {

//#region src/lib/media.ts
/** Titles and names are cut to this many characters. */
	const LIMIT = 200;
	/**
	* The element the strip controls: one playing with sound, else one playing
	* at all, else the one furthest into its media (paused part way).
	*/
	function currentMedia(root) {
		const all = [...root.querySelectorAll("video, audio")];
		const playing = all.filter((media) => !media.paused && !media.ended);
		return playing.find((media) => !media.muted && media.volume > 0) ?? playing[0] ?? all.filter((media) => media.currentTime > 0 && !media.ended).toSorted((a, b) => b.currentTime - a.currentTime)[0] ?? null;
	}
	function clip(text) {
		return (text ?? "").trim().slice(0, 200);
	}
	/** The report for `media`, or null when there is nothing to control. */
	function describe(media, metadata, pageTitle, actions) {
		if (!media) return null;
		return {
			title: clip(metadata?.title) || clip(pageTitle),
			artist: clip(metadata?.artist),
			playing: !media.paused && !media.ended,
			actions: [...actions].toSorted()
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
		window.setInterval(() => {
			if (sent.includes("\"playing\":true")) report();
		}, 2e3);
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