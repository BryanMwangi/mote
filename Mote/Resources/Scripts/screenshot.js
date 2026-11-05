// Generated from Scripts/src/screenshot.ts by `pnpm build`. Do not edit.
var moteScreenshot = (function(exports) {

Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
//#region src/element-picker/describe.ts
/**
	* Names for elements whose tag says what they are. A Map, not an object: a page
	* can name an element `constructor` or `__proto__`.
	*/
	const KINDS = /* @__PURE__ */ new Map([
		["nav", "Navigation"],
		["header", "Header"],
		["footer", "Footer"],
		["aside", "Sidebar"],
		["form", "Form"],
		["dialog", "Dialog"],
		["video", "Video"],
		["img", "Image"],
		["button", "Button"],
		["iframe", "Embed"],
		["figure", "Figure"],
		["table", "Table"]
	]);
	/** Longest name shown, in characters. */
	const MAX_NAME_LENGTH = 40;
	/** Cuts `text` to `length` characters, marking the cut with an ellipsis. */
	function clip(text, length) {
		return text.length > length ? `${text.slice(0, length)}…` : text;
	}
	/**
	* What an element is, in the order a person would answer the question: what it
	* calls itself, then what kind of thing it is, then what it says.
	*/
	function elementName(element) {
		const said = element.getAttribute("aria-label") || element.getAttribute("title");
		if (said && said.trim()) return clip(said.trim(), MAX_NAME_LENGTH);
		const tag = element.localName;
		const kind = KINDS.get(tag);
		if (kind) return kind;
		const role = element.getAttribute("role");
		if (role) return role.charAt(0).toUpperCase() + role.slice(1);
		const text = (element.innerText || "").trim().replace(/\s+/g, " ");
		return text ? clip(text, MAX_NAME_LENGTH) : tag;
	}

//#endregion
//#region src/screenshot.ts
	const STYLE = `
  :host { all: initial; }
  .dim { position: fixed; inset: 0; z-index: 2147483646; cursor: crosshair; background: rgba(0,0,0,.45);
    font: 13px -apple-system, BlinkMacSystemFont, sans-serif; color: #fff; }
  /* With a box out, its shadow dims the rest instead. */
  .dim.boxed { background: transparent; }
  .hint { position: fixed; left: 50%; top: 50%; transform: translate(-50%, -50%); text-align: center;
    font-size: 22px; font-weight: 500; line-height: 1.35; pointer-events: none; max-width: 520px; }
  .hint button { pointer-events: auto; margin-top: 18px; }
  .box { position: fixed; display: none; border: 2px dashed rgba(255,255,255,.95); border-radius: 3px;
    box-shadow: 0 0 0 99999px rgba(0,0,0,.45); pointer-events: none; }
  .tag { position: absolute; top: -24px; left: 0; background: #171717; color: #fff; font-size: 11px;
    padding: 2px 7px; border-radius: 5px; white-space: nowrap; }
  .corner { position: fixed; top: 12px; right: 12px; display: flex; gap: 8px; padding: 8px;
    background: rgba(40,40,40,.9); border-radius: 12px; }
  .actions { position: fixed; display: none; gap: 8px; }
  button { font: 500 12px -apple-system, BlinkMacSystemFont, sans-serif; color: #fff; background: rgba(60,60,60,.95);
    border: 1px solid rgba(255,255,255,.18); border-radius: 8px; padding: 7px 12px; cursor: default; }
  button:hover { background: rgba(85,85,85,.95); }
  button.main { background: #fff; color: #171717; }
`;
	function run() {
		return new Promise((resolve) => {
			const host = document.createElement("div");
			const root = host.attachShadow({ mode: "closed" });
			root.innerHTML = `<style>${STYLE}</style>
      <div class="dim">
        <div class="box"><div class="tag"></div></div>
        <div class="hint">Drag or click on the page to select a region.<br>Press Esc to cancel.<br><button data-do="cancel">Cancel</button></div>
        <div class="corner"><button data-do="visible">Save Visible</button><button data-do="full">Save Full Page</button></div>
        <div class="actions"><button data-do="cancel">Cancel</button><button data-do="copy">Copy</button><button data-do="save" class="main">Download</button></div>
      </div>`;
			document.documentElement.appendChild(host);
			const dim = root.querySelector(".dim");
			const box = root.querySelector(".box");
			const tag = root.querySelector(".tag");
			const hint = root.querySelector(".hint");
			const actions = root.querySelector(".actions");
			let picked = null;
			let hovered = null;
			let start = null;
			const show = (rect, label) => {
				box.style.display = "block";
				dim.classList.add("boxed");
				Object.assign(box.style, {
					left: `${rect.left}px`,
					top: `${rect.top}px`,
					width: `${rect.width}px`,
					height: `${rect.height}px`
				});
				tag.textContent = label;
				tag.style.display = label ? "block" : "none";
			};
			/** What's under the overlay at a point. */
			const under = (x, y) => {
				host.style.pointerEvents = "none";
				const found = document.elementFromPoint(x, y);
				host.style.pointerEvents = "";
				return found === document.documentElement || found === document.body ? null : found;
			};
			const finish = (choice) => {
				document.removeEventListener("keydown", onKey, true);
				host.remove();
				requestAnimationFrame(() => requestAnimationFrame(() => resolve(choice)));
			};
			const onKey = (event) => {
				if (event.key !== "Escape") return;
				event.preventDefault();
				event.stopPropagation();
				finish({ kind: "cancel" });
			};
			document.addEventListener("keydown", onKey, true);
			root.addEventListener("click", (event) => {
				const what = event.target.closest("button")?.dataset.do;
				if (!what) return;
				event.stopPropagation();
				if (what === "copy" || what === "save") {
					if (!picked) return;
					finish({
						kind: what,
						rect: [
							picked.left + scrollX,
							picked.top + scrollY,
							picked.width,
							picked.height
						],
						scroll: [scrollX, scrollY]
					});
				} else finish({ kind: what });
			});
			dim.addEventListener("mousemove", (event) => {
				if (picked) return;
				if (start && event.buttons & 1) {
					const left = Math.min(start.x, event.clientX);
					const top = Math.min(start.y, event.clientY);
					show(new DOMRect(left, top, Math.abs(event.clientX - start.x), Math.abs(event.clientY - start.y)), "");
					return;
				}
				const element = under(event.clientX, event.clientY);
				hovered = element ? element.getBoundingClientRect() : null;
				if (element && hovered) show(hovered, elementName(element));
				else {
					box.style.display = "none";
					dim.classList.remove("boxed");
				}
			});
			dim.addEventListener("mousedown", (event) => {
				if (picked || event.target.closest("button")) return;
				event.preventDefault();
				start = {
					x: event.clientX,
					y: event.clientY
				};
			});
			dim.addEventListener("mouseup", (event) => {
				if (picked || !start) return;
				const rect = Math.abs(event.clientX - start.x) > 4 || Math.abs(event.clientY - start.y) > 4 ? new DOMRect(Math.min(start.x, event.clientX), Math.min(start.y, event.clientY), Math.abs(event.clientX - start.x), Math.abs(event.clientY - start.y)) : hovered;
				start = null;
				if (!rect || rect.width < 2 || rect.height < 2) return;
				picked = rect;
				show(rect, "");
				hint.style.display = "none";
				const top = Math.min(rect.bottom + 8, innerHeight - 44);
				Object.assign(actions.style, {
					display: "flex",
					top: `${top}px`,
					left: `${Math.max(8, Math.min(rect.right - 230, innerWidth - 238))}px`
				});
			});
		});
	}

//#endregion
exports.run = run;
return exports;
})({});