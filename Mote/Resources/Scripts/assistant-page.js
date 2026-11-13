// Generated from Scripts/src/assistant-page.ts by `pnpm build`. Do not edit.
var moteAssistantPage = (function(exports) {

Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
//#region src/assistant-page.ts
	const PICKABLE = "a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=tab],[role=menuitem],[contenteditable=\"\"],[contenteditable=true]";
	/** The most elements listed at once, and the most of a list's or table's text. */
	const MOST = 250;
	const MOST_TEXT = 2e4;
	function shown(item) {
		const box = item.getBoundingClientRect();
		return box.width > 0 && box.height > 0;
	}
	function isPassword(item) {
		return item instanceof HTMLInputElement && item.type === "password";
	}
	/** An editor the page draws itself (an email's body), as the browser marks it. */
	function isEditor(item) {
		const said = item.getAttribute("contenteditable");
		return item.isContentEditable || said === "" || said === "true";
	}
	/** What an element says it is, briefly, for the list and the person's question. */
	function describe(item) {
		const input = item;
		return (item.innerText || item.getAttribute("aria-label") || input.placeholder || item.getAttribute("title") || input.name || (["submit", "button"].includes(input.type) ? input.value : "") || "").trim().replace(/\s+/g, " ").slice(0, 80);
	}
	/** Numbers what can be picked, keeping earlier numbers; the list as text. */
	function outline(root = document) {
		const known = window.__moteOutline ??= [];
		for (const item of root.querySelectorAll(PICKABLE)) {
			if (known.length >= 2e3) break;
			if (!known.includes(item)) known.push(item);
		}
		const lines = [];
		known.forEach((item, n) => {
			if (lines.length >= MOST || !item.isConnected || !shown(item)) return;
			const input = item;
			const kind = item.tagName.toLowerCase() + (input.type ? `(${input.type})` : "");
			const state = input.type === "checkbox" || input.type === "radio" ? input.checked ? " [on]" : " [off]" : "";
			const href = item.href ? ` -> ${item.href}` : "";
			lines.push(`[${n}] ${kind} ${describe(item)}${state}${href}`);
		});
		return lines.join("\n");
	}
	/** The element numbered `n`, while it's still in the page. */
	function numbered(n) {
		if (n === void 0) return null;
		const found = window.__moteOutline?.[n];
		return found && found.isConnected ? found : null;
	}
	function setValue(field, value) {
		const prototype = field instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
		const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
		if (setter) setter.call(field, value);
		else field.value = value;
		field.dispatchEvent(new Event("input", { bubbles: true }));
		field.dispatchEvent(new Event("change", { bubbles: true }));
	}
	/**
	* Writes into a field or an editor: plain fields through the value setter, as
	* typing would; rich editors (an email's body) through insertText, which they
	* take as typing, so their undo and handlers work. No number: where the caret is.
	*/
	function write(target, text, how = "replace") {
		const field = target ?? document.activeElement;
		if (!field || field === document.body) return "nowhere";
		if (isPassword(field)) return "password";
		field.focus();
		if (field instanceof HTMLInputElement || field instanceof HTMLTextAreaElement) {
			if (field.readOnly || field.disabled) return "locked";
			const now = field.value;
			setValue(field, how === "append" ? now + text : how === "insert" ? insertAtCaret(field, text) : text);
			return "done";
		}
		if (isEditor(field)) {
			const selection = window.getSelection();
			if (how === "replace" && selection) selection.selectAllChildren(field);
			else if (how === "append" && selection) {
				selection.selectAllChildren(field);
				selection.collapseToEnd();
			}
			if (!(typeof document.execCommand === "function" && document.execCommand("insertText", false, text))) {
				field.textContent = how === "append" ? (field.textContent ?? "") + text : text;
				field.dispatchEvent(new InputEvent("input", {
					bubbles: true,
					data: text
				}));
			}
			return "done";
		}
		return "not-editable";
	}
	function insertAtCaret(field, text) {
		const start = field.selectionStart ?? field.value.length;
		const end = field.selectionEnd ?? start;
		return field.value.slice(0, start) + text + field.value.slice(end);
	}
	/** What a field holds; never a password. */
	function readField(target) {
		if (!target) return "gone";
		if (isPassword(target)) return "password";
		if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement) return target.value;
		return target.innerText ?? "";
	}
	/** Picks an option of a list by its value or what it says. */
	function choose(target, value) {
		if (!(target instanceof HTMLSelectElement)) return target ? "not-a-list" : "gone";
		const wanted = value.trim().toLowerCase();
		const option = [...target.options].find((item) => item.value.toLowerCase() === wanted || item.text.trim().toLowerCase() === wanted);
		if (!option) return `no-option: ${[...target.options].map((item) => item.text.trim()).join(" | ")}`;
		target.value = option.value;
		target.dispatchEvent(new Event("input", { bubbles: true }));
		target.dispatchEvent(new Event("change", { bubbles: true }));
		return "done";
	}
	/** Ticks or unticks a box, by clicking it so the page hears it. */
	function check(target, on) {
		if (!target) return "gone";
		if ((target instanceof HTMLInputElement ? target.checked : target.getAttribute("aria-checked") === "true") !== on) target.click();
		return "done";
	}
	/** Up to twenty places the words appear, each with some of what's around it. */
	function find(text, root = document) {
		const needle = text.trim().toLowerCase();
		if (!needle) return [];
		const found = [];
		const walker = root.createTreeWalker(root.body, NodeFilter.SHOW_TEXT);
		for (let node = walker.nextNode(); node && found.length < 20; node = walker.nextNode()) {
			const words = node.textContent ?? "";
			let at = words.toLowerCase().indexOf(needle);
			while (at >= 0 && found.length < 20) {
				const start = Math.max(0, at - 80);
				found.push(words.slice(start, at + needle.length + 80).replace(/\s+/g, " ").trim());
				at = words.toLowerCase().indexOf(needle, at + needle.length);
			}
		}
		return found;
	}
	/** The page's tables as Markdown, one after another. */
	function tables(root = document) {
		const out = [];
		let length = 0;
		for (const table of root.querySelectorAll("table")) {
			const rows = [...table.rows].map((row) => [...row.cells].map((cell) => (cell.innerText || cell.textContent || "").trim().replace(/\s+/g, " ").replace(/\|/g, "\\|")));
			if (rows.length === 0) continue;
			const width = Math.max(...rows.map((row) => row.length));
			const line = (cells) => `| ${[...cells, ...Array(width - cells.length).fill("")].join(" | ")} |`;
			const text = [
				line(rows[0]),
				line(Array(width).fill("---")),
				...rows.slice(1).map(line)
			].join("\n");
			if (length + text.length > MOST_TEXT) break;
			out.push(text);
			length += text.length;
		}
		return out.join("\n\n");
	}
	/** Where an element is in the window, for the cursor to go to; null if gone. */
	function place(target) {
		if (!target) return null;
		const box = target.getBoundingClientRect();
		return {
			x: box.x,
			y: box.y,
			w: box.width,
			h: box.height,
			sx: window.scrollX,
			sy: window.scrollY
		};
	}
	function run(op, args = {}) {
		const target = numbered(args.n);
		switch (op) {
			case "outline": return outline();
			case "describe": return target ? describe(target) : null;
			case "rect":
				if (target) target.scrollIntoView({
					block: "center",
					inline: "nearest"
				});
				return place(target);
			case "click":
				if (!target) return "gone";
				target.click();
				return "done";
			case "focus":
				if (!target) return "gone";
				target.focus();
				return "done";
			case "write":
				if (args.n !== void 0 && !target) return "gone";
				return write(target, args.text ?? "", args.how);
			case "read": return readField(target);
			case "choose": return choose(target, args.value ?? "");
			case "check": return check(target, args.on ?? true);
			case "scroll":
				if (target) target.scrollIntoView({ block: "center" });
				else if (args.to === "top") window.scrollTo({ top: 0 });
				else if (args.to === "bottom") window.scrollTo({ top: document.documentElement.scrollHeight });
				else window.scrollBy({ top: args.by ?? window.innerHeight * .8 });
				return "done";
			case "key": {
				const at = target ?? document.activeElement ?? document.body;
				for (const type of [
					"keydown",
					"keypress",
					"keyup"
				]) at.dispatchEvent(new KeyboardEvent(type, {
					key: args.key ?? "Enter",
					bubbles: true,
					cancelable: true
				}));
				if (args.key === "Enter" && at instanceof HTMLInputElement) at.form?.requestSubmit();
				return "done";
			}
			case "find": return find(args.text ?? "");
			case "tables": return tables();
			case "selection": return window.getSelection()?.toString() ?? "";
			case "code": {
				const field = document.querySelector("input[autocomplete=\"one-time-code\"], input[name*=\"otp\" i], input[name*=\"code\" i][inputmode=\"numeric\"]");
				return field ? write(field, args.text ?? "", "replace") : "nowhere";
			}
			default: return "unknown";
		}
	}

//#endregion
exports.check = check;
exports.choose = choose;
exports.describe = describe;
exports.find = find;
exports.outline = outline;
exports.place = place;
exports.readField = readField;
exports.run = run;
exports.tables = tables;
exports.write = write;
return exports;
})({});