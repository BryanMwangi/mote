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
	* `loose`: elements playing outside the page, as a music player's own `Audio`.
	*/
	function currentMedia(root, loose = []) {
		const all = [...root.querySelectorAll("video, audio"), ...loose].filter(audible);
		return all.find((media) => !media.paused && !media.ended) ?? all.filter((media) => media.currentTime > 0 && !media.ended).toSorted((a, b) => b.currentTime - a.currentTime)[0] ?? null;
	}
	function clip(text) {
		return (text ?? "").trim().slice(0, 200);
	}
	/**
	* The report for `media`, or null when there is nothing to control. With no
	* element in sight, a site that describes its track and plays and pauses it
	* itself is still a player: `state`, its `playbackState`, says whether it plays.
	*/
	function describe(media, metadata, pageTitle, actions, state = "none") {
		const handled = [...actions].toSorted();
		const runsItself = Boolean(metadata?.title) && handled.includes("play") && handled.includes("pause") && state !== "none";
		if (!media && !runsItself) return null;
		return {
			title: clip(metadata?.title) || clip(pageTitle),
			artist: clip(metadata?.artist),
			playing: media ? !media.paused && !media.ended : state === "playing",
			actions: handled,
			session: Boolean(metadata?.title) || handled.length > 0,
			video: media instanceof HTMLVideoElement && media.videoWidth > 0
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
		const loose = /* @__PURE__ */ new Set();
		const play = HTMLMediaElement.prototype.play;
		HTMLMediaElement.prototype.play = function() {
			if (!this.isConnected && !loose.has(this)) {
				if (loose.size >= 4) loose.delete(loose.values().next().value);
				loose.add(this);
				for (const kind of [
					"play",
					"pause",
					"ended",
					"emptied",
					"loadedmetadata",
					"volumechange"
				]) this.addEventListener(kind, soon);
				this.addEventListener("timeupdate", progress);
			}
			return play.call(this);
		};
		const playing = () => currentMedia(document, loose);
		let sent = "";
		const report = () => {
			const media = playing();
			const found = describe(media, session?.metadata, document.title, handlers.keys(), session?.playbackState);
			const message = JSON.stringify(found);
			if (message === sent) return;
			sent = message;
			handler.postMessage(message);
		};
		let waiting;
		function soon() {
			clearTimeout(waiting);
			waiting = window.setTimeout(report, 150);
		}
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
			const media = playing();
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
			const media = playing();
			switch (command) {
				case "toggle":
					if (media ? !media.paused : session?.playbackState === "playing") {
						if (!call("pause")) media?.pause();
					} else if (!call("play")) media?.play().catch(() => {});
					break;
				case "next":
					if (!call("nexttrack") && media) media.currentTime = Math.min(media.duration || Infinity, media.currentTime + 10);
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