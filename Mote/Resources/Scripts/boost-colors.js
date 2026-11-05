// Generated from Scripts/src/boost-colors.ts by `pnpm build`. Do not edit.
var moteBoostColors = (function(exports) {

Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
//#region src/boost-colors.ts
	const PROPERTIES = [
		"color",
		"background-color",
		"border-top-color",
		"border-right-color",
		"border-bottom-color",
		"border-left-color"
	];
	const SKIP = /^(IMG|PICTURE|VIDEO|CANVAS|IFRAME|svg|image|SOURCE)$/;
	/** Elements done at a time, so a long page never holds one up. */
	const PER_FRAME = 700;
	const linear = (c) => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4;
	const srgb = (c) => c <= .0031308 ? 12.92 * c : 1.055 * Math.max(c, 0) ** (1 / 2.4) - .055;
	function oklab([r, g, b]) {
		const [lr, lg, lb] = [
			linear(r / 255),
			linear(g / 255),
			linear(b / 255)
		];
		const l = Math.cbrt(.4122214708 * lr + .5363325363 * lg + .0514459929 * lb);
		const m = Math.cbrt(.2119034982 * lr + .6806995451 * lg + .1073969566 * lb);
		const s = Math.cbrt(.0883024619 * lr + .2817188376 * lg + .6299787005 * lb);
		return [
			.2104542553 * l + .793617785 * m - .0040720468 * s,
			1.9779984951 * l - 2.428592205 * m + .4505937099 * s,
			.0259040371 * l + .7827717662 * m - .808675766 * s
		];
	}
	const channel = (v) => Math.round(Math.min(Math.max(srgb(v), 0), 1) * 255);
	function rgb([L, A, B]) {
		const l = (L + .3963377774 * A + .2158037573 * B) ** 3;
		const m = (L - .1055613458 * A - .0638541728 * B) ** 3;
		const s = (L - .0894841775 * A - 1.291485548 * B) ** 3;
		return [
			channel(4.0767416621 * l - 3.3077115913 * m + .2309699292 * s),
			channel(-1.2684380046 * l + 2.6097574011 * m - .3413193965 * s),
			channel(-.0041960863 * l - .7034186147 * m + 1.707614701 * s)
		];
	}
	const hex = (text) => [
		1,
		3,
		5
	].map((at) => parseInt(text.slice(at, at + 2), 16));
	/** Zen's zenFilterColorChannel: `color` moved toward the dots by `strength`. */
	function filter(color, first, second, strength) {
		const [L, A, B] = oklab(color);
		const half = Math.min(Math.max(.5 - strength * .45, .05), .5);
		let t = Math.min(Math.max((L - (.5 - half)) / (2 * half), 0), 1);
		t = t * t * (3 - 2 * t);
		const pick = first.map((v, i) => v + (second[i] - v) * t);
		const a = A + (pick[1] - A) * strength;
		const b = B + (pick[2] - B) * strength;
		const shift = pick[0] - L;
		const lightness = L + shift * strength * strength * .5;
		const turn = (shift > 0 ? -1 : 1) * strength * strength * .25;
		return rgb([
			lightness,
			a * Math.cos(turn) - b * Math.sin(turn),
			a * Math.sin(turn) + b * Math.cos(turn)
		]);
	}
	const parse = (value) => {
		const found = /^rgba?\(([\d.]+),\s*([\d.]+),\s*([\d.]+)(?:,\s*([\d.]+))?\)$/.exec(value);
		if (!found || found[4] === "0") return null;
		return {
			color: [
				Number(found[1]),
				Number(found[2]),
				Number(found[3])
			],
			alpha: found[4] ?? "1"
		};
	};
	if (!window.__moteBoostColors) {
		/** Each element's own colours before the boost, and its inline ones to put back. */
		const original = /* @__PURE__ */ new WeakMap();
		const touched = /* @__PURE__ */ new Set();
		let current = null;
		let queue = [];
		let scheduled = false;
		const paint = (element) => {
			if (!current || SKIP.test(element.tagName) || !(element instanceof HTMLElement || element instanceof SVGElement)) return;
			let saved = original.get(element);
			if (!saved) {
				const style = getComputedStyle(element);
				saved = {
					computed: PROPERTIES.map((property) => style.getPropertyValue(property)),
					inline: PROPERTIES.map((property) => element.style.getPropertyValue(property))
				};
				original.set(element, saved);
			}
			PROPERTIES.forEach((property, i) => {
				const read = parse(saved.computed[i] ?? "");
				if (!read || !current) return;
				const [r, g, b] = filter(read.color, current.first, current.second, current.strength);
				element.style.setProperty(property, `rgba(${r}, ${g}, ${b}, ${read.alpha})`, "important");
			});
			touched.add(element);
		};
		const drain = () => {
			scheduled = false;
			for (const element of queue.splice(0, PER_FRAME)) paint(element);
			if (queue.length) schedule();
		};
		const schedule = () => {
			if (scheduled) return;
			scheduled = true;
			setTimeout(drain, 0);
		};
		const unpaint = () => {
			for (const element of touched) {
				const saved = original.get(element);
				if (!saved || !(element instanceof HTMLElement || element instanceof SVGElement)) continue;
				PROPERTIES.forEach((property, i) => {
					const value = saved.inline[i];
					if (value) element.style.setProperty(property, value);
					else element.style.removeProperty(property);
				});
			}
			touched.clear();
		};
		const start = () => {
			const root = document.documentElement;
			if (!parse(getComputedStyle(root).backgroundColor) && document.body && !parse(getComputedStyle(document.body).backgroundColor)) root.style.setProperty("background-color", "rgb(255, 255, 255)");
			queue = [root, ...document.querySelectorAll("*")];
			schedule();
		};
		new MutationObserver((changes) => {
			if (!current) return;
			for (const change of changes) for (const node of change.addedNodes) if (node instanceof Element) queue.push(node, ...node.querySelectorAll("*"));
			if (queue.length) schedule();
		}).observe(document, {
			childList: true,
			subtree: true
		});
		window.__moteBoostColors = { set(colors) {
			unpaint();
			queue = [];
			current = colors.primary && colors.strength > 0 ? {
				first: oklab(hex(colors.primary)),
				second: oklab(hex(colors.secondary ?? colors.primary)),
				strength: Math.min(colors.strength, 1)
			} : null;
			if (!current) return;
			if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
			else start();
		} };
	}
	window.__moteBoostColors.set(moteConfig);

//#endregion
exports.filter = filter;
exports.oklab = oklab;
exports.rgb = rgb;
return exports;
})({});