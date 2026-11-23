// Generated from Scripts/src/assistant-page.ts by `pnpm build`. Do not edit.
var moteAssistantPage = (function(exports) {

Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' });
//#region src/assistant-page.ts
	const PICKABLE = "a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=switch],[role=tab],[role=menuitem],[role=menuitemcheckbox],[role=menuitemradio],[role=combobox],[role=listbox],[role=option],[role=textbox],[contenteditable=\"\"],[contenteditable=true]";
	/** The most elements listed at once, and the most of a list's or table's text. */
	const MOST = 150;
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
		return ((item instanceof HTMLSelectElement ? "" : item.innerText) || item.getAttribute("aria-label") || input.placeholder || item.getAttribute("title") || input.name || (["submit", "button"].includes(input.type) ? input.value : "") || "").trim().replace(/\s+/g, " ").slice(0, 80);
	}
	function isFileField(item) {
		return item instanceof HTMLInputElement && item.type === "file";
	}
	/** The file field an element stands for: itself, one inside it, the one its
	* label is for, or the one beside it (a button over a hidden field). */
	function fileFieldFor(item) {
		if (isFileField(item)) return item;
		const inside = item.querySelector("input[type=file]");
		if (isFileField(inside)) return inside;
		const labelled = item.closest("label")?.control ?? null;
		if (isFileField(labelled)) return labelled;
		let around = item.parentElement;
		for (let up = 0; around && up < 3; up++, around = around.parentElement) {
			const near = around.querySelectorAll("input[type=file]");
			if (near.length === 1 && isFileField(near[0])) return near[0];
		}
		return null;
	}
	/** Puts files from the Mac into a file field, as choosing them would. */
	function attach(target, files) {
		if (!target) return "gone";
		const field = fileFieldFor(target);
		if (!field) return "not-a-file-field";
		if (field.disabled) return "locked";
		if (files.length > 1 && !field.multiple) return "one-file-only";
		const chosen = new DataTransfer();
		for (const file of files) {
			const bytes = Uint8Array.from(atob(file.data), (char) => char.charCodeAt(0));
			chosen.items.add(new File([bytes], file.name, { type: file.type }));
		}
		field.files = chosen.files;
		field.dispatchEvent(new Event("input", { bubbles: true }));
		field.dispatchEvent(new Event("change", { bubbles: true }));
		return "done";
	}
	/** A form field, or a widget that stands for one, as opposed to a link or button. */
	function isField(item) {
		if (item instanceof HTMLInputElement) return ![
			"submit",
			"button",
			"reset",
			"image"
		].includes(item.type);
		return item instanceof HTMLSelectElement || item instanceof HTMLTextAreaElement || isEditor(item) || [
			"combobox",
			"textbox",
			"listbox"
		].includes(item.getAttribute("role") ?? "");
	}
	/** Words for the list, kept short and on one line. */
	function brief(said, most = 60) {
		const line = said.trim().replace(/\s+/g, " ");
		return line.length > most ? `${line.slice(0, most - 1)}…` : line;
	}
	/** What a field holds now, as the person sees it: a list's chosen option by
	* what it says (its value when it says nothing), never a password. */
	function shownValue(item) {
		if (item instanceof HTMLSelectElement) {
			const option = item.options[item.selectedIndex];
			if (!option) return "";
			return option.text.trim() || option.value;
		}
		if (item instanceof HTMLInputElement) {
			if (["checkbox", "radio"].includes(item.type)) return null;
			if (item.type === "password") return item.value ? "••••" : "";
			if (item.type === "file") return [...item.files ?? []].map((file) => file.name).join(", ");
			return item.value;
		}
		if (item instanceof HTMLTextAreaElement) return item.value;
		if (isField(item)) return item.innerText ?? "";
		return null;
	}
	/** Required, and whether the page or the browser finds it wrong, with why. */
	function validity(item) {
		const field = item;
		const notes = [];
		if (field.required || item.getAttribute("aria-required") === "true") notes.push("required");
		if ((field.validity ? !field.validity.valid : false) || item.getAttribute("aria-invalid") === "true") notes.push(field.validationMessage ? `invalid: ${brief(field.validationMessage)}` : "invalid");
		return notes.length ? ` (${notes.join(", ")})` : "";
	}
	/** On or off, open, chosen: what a box, a dropdown or an option says of itself. */
	function state(item) {
		const input = item;
		if (input.type === "checkbox" || input.type === "radio") return input.checked ? " [on]" : " [off]";
		const checked = item.getAttribute("aria-checked");
		if (checked) return checked === "true" ? " [on]" : " [off]";
		if (item.getAttribute("aria-selected") === "true") return " [chosen]";
		if (item.getAttribute("aria-expanded") === "true") return " [open]";
		return "";
	}
	/** One line of the list: number, kind, name, what it holds, its state, where it goes. */
	function entry(item, n) {
		const input = item;
		const role = item.getAttribute("role");
		const kind = role && (role === "combobox" || !(item instanceof HTMLInputElement)) ? role : item.tagName.toLowerCase() + (input.type ? `(${input.type})` : "");
		const field = isField(item);
		const name = field ? brief(labelOf(item)) || describe(item) : describe(item);
		const value = field ? shownValue(item) : null;
		const holds = value === null ? "" : value === "" ? " = (empty)" : ` = "${brief(value)}"`;
		const href = item.href ? ` -> ${item.href}` : "";
		return `[${n}] ${kind} ${name}${holds}${state(item)}${field ? validity(item) : ""}${href}`;
	}
	/** Numbers what can be picked, keeping earlier numbers; the list as text. */
	function outline(root = document, after = -1) {
		const known = window.__moteOutline ??= [];
		for (const item of root.querySelectorAll(PICKABLE)) {
			if (known.length >= 2e3) break;
			if (!known.includes(item)) known.push(item);
		}
		const lines = [];
		let more = 0;
		let last = after;
		known.forEach((item, n) => {
			if (n <= after || !item.isConnected || !shown(item) && !isFileField(item)) return;
			if (lines.length >= MOST) return void more++;
			lines.push(entry(item, n));
			last = n;
		});
		if (more) lines.push(`(${more} more: read_tab with elements_after: ${last})`);
		return lines.join("\n");
	}
	/** The fields the page would refuse to send as they are: required and empty,
	* or wrong by the browser's or the page's own checks. One line each. */
	function problems() {
		if (!window.__moteOutline?.length) outline();
		return (window.__moteOutline ?? []).flatMap((item, n) => {
			if (!item.isConnected || !isField(item)) return [];
			const said = validity(item);
			const field = item;
			const empty = shownValue(item) === "" && !(field.type === "checkbox" && field.checked);
			const required = said.includes("required");
			if (!said.includes("invalid") && !(required && empty)) return [];
			return [entry(item, n)];
		});
	}
	/** The element numbered `n`, while it's still in the page. */
	/** A field's label, as a person reads it: its <label>, else what it says it is. */
	function labelOf(item) {
		const field = item;
		const byFor = field.labels?.[0] ?? (field.id ? document.querySelector(`label[for="${CSS.escape(field.id)}"]`) : null);
		const wrapping = item.closest("label");
		const named = item.getAttribute("aria-labelledby");
		const labelled = named ? named.split(/\s+/).map((id) => document.getElementById(id)?.textContent ?? "").join(" ") : "";
		const own = (label) => (label?.textContent ?? "").replace(item.textContent ?? "", "");
		return (own(byFor) || labelled || item.getAttribute("aria-label") || own(wrapping) || field.placeholder || item.getAttribute("title") || item.closest("fieldset")?.querySelector("legend")?.textContent || field.name || "").trim().replace(/\s+/g, " ");
	}
	/** The number of the form field whose label says `label`: the same words, else containing them. */
	function findField(label) {
		if (!window.__moteOutline?.length) outline();
		const known = window.__moteOutline ?? [];
		const wanted = label.trim().toLowerCase();
		const fields = known.map((item, n) => ({
			item,
			n
		})).filter(({ item }) => item.isConnected && isField(item));
		const near = fields.find(({ item }) => labelOf(item).toLowerCase() === wanted) ?? fields.find(({ item }) => labelOf(item).toLowerCase().includes(wanted));
		return near ? near.n : null;
	}
	/** What kind of field an element is, for filling it the right way. */
	function kindOf(item) {
		if (!item) return "gone";
		if (item instanceof HTMLSelectElement || isList(item)) return "select";
		if (item instanceof HTMLInputElement) {
			if ([
				"checkbox",
				"radio",
				"password",
				"file"
			].includes(item.type)) return item.type;
			return "text";
		}
		const role = item.getAttribute("role");
		if (role === "checkbox" || role === "switch") return "checkbox";
		if (role === "radio") return "radio";
		return "text";
	}
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
	/** Picks an option of a list by its value or what it says: a page's own
	* dropdown or autocomplete (role combobox or listbox) is opened, typed
	* into when it takes typing, and its option clicked. */
	function choose(target, value) {
		if (target && !(target instanceof HTMLSelectElement) && isList(target)) return pick(target, value);
		if (!(target instanceof HTMLSelectElement)) return target ? "not-a-list" : "gone";
		const wanted = value.trim().toLowerCase();
		const option = [...target.options].find((item) => item.value.toLowerCase() === wanted || item.text.trim().toLowerCase() === wanted);
		if (!option) return `no-option: ${[...target.options].map((item) => item.text.trim()).join(" | ")}`;
		target.value = option.value;
		target.dispatchEvent(new Event("input", { bubbles: true }));
		target.dispatchEvent(new Event("change", { bubbles: true }));
		return "done";
	}
	function isList(item) {
		const role = item.getAttribute("role");
		return role === "combobox" || role === "listbox" || item.getAttribute("aria-haspopup") === "listbox";
	}
	/** The options a dropdown shows now: in the list it names, else anywhere
	* (pages draw them at the end of the body). */
	function optionsOf(owner) {
		const named = (owner.getAttribute("aria-controls") ?? owner.getAttribute("aria-owns") ?? "").split(/\s+/).flatMap((id) => id ? [document.getElementById(id)] : []).filter((box) => !!box);
		return (owner.getAttribute("role") === "listbox" ? [owner] : named.length ? named : [document]).flatMap((list) => [...list.querySelectorAll("[role=option]")]).filter((option) => shown(option) && option.getAttribute("aria-disabled") !== "true");
	}
	/** A click where a pointer would land: on what is drawn at the element's
	* middle, which is where pages listen (a dropdown's inner trigger). */
	function press(item, down = false) {
		item.scrollIntoView({ block: "nearest" });
		const box = item.getBoundingClientRect();
		const drawn = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
		const at = drawn && item.contains(drawn) ? drawn : item;
		if (down) for (const type of ["pointerdown", "mousedown"]) at.dispatchEvent(new MouseEvent(type, {
			bubbles: true,
			cancelable: true,
			view: window
		}));
		at.click();
	}
	/** What `look` gives once it gives something, or null after `ms`. */
	async function soon(look, ms) {
		for (const end = Date.now() + ms;;) {
			const found = look();
			if (found || Date.now() > end) return found;
			await new Promise((done) => setTimeout(done, 50));
		}
	}
	const wordsOf = (option) => (option.textContent ?? "").trim().replace(/\s+/g, " ").toLowerCase();
	async function pick(target, value) {
		const wanted = value.trim().replace(/\s+/g, " ").toLowerCase();
		const listed = () => {
			const options = optionsOf(target);
			return options.length ? options : null;
		};
		if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
			target.focus();
			setValue(target, value);
		}
		if (!listed()) press(target);
		const options = await soon(listed, 700) ?? (press(target, true), await soon(listed, 1800));
		if (!options) return "no-options";
		const option = options.find((item) => wordsOf(item) === wanted || item.getAttribute("data-value")?.toLowerCase() === wanted) ?? options.find((item) => wordsOf(item).includes(wanted));
		if (!option) return `no-option: ${options.slice(0, 40).map((item) => brief(item.textContent ?? "")).join(" | ")}`;
		press(option);
		return "done";
	}
	/** What scrolls the page: the document, or when it doesn't move, the
	* largest box of the page's own that does (a web app's main pane). */
	function scroller() {
		const page = document.scrollingElement ?? document.documentElement;
		if (page.scrollHeight > page.clientHeight + 1) return page;
		let best = page;
		let most = 0;
		for (const box of document.body?.querySelectorAll("*") ?? []) {
			if (box.scrollHeight <= box.clientHeight + 1) continue;
			const overflow = getComputedStyle(box).overflowY;
			if (overflow !== "auto" && overflow !== "scroll") continue;
			const area = box.clientWidth * box.clientHeight;
			if (area > most) [best, most] = [box, area];
		}
		return best;
	}
	/** Scrolls, then says where the page is and how far it went: an agent can
	* tell a page that moved from one that's at its end or doesn't scroll. */
	async function scroll(target, args) {
		const box = scroller();
		const before = box.scrollTop;
		const room = box.scrollHeight - box.clientHeight;
		if (target) target.scrollIntoView({
			block: "center",
			behavior: "instant"
		});
		else if (args.to === "top") box.scrollTo({
			top: 0,
			behavior: "instant"
		});
		else if (args.to === "bottom") box.scrollTo({
			top: room,
			behavior: "instant"
		});
		else box.scrollBy({
			top: args.by ?? box.clientHeight * .8,
			behavior: "instant"
		});
		await new Promise((done) => setTimeout(done, 60));
		const at = Math.round(box.scrollTop);
		const most = Math.round(box.scrollHeight - box.clientHeight);
		if (most <= 0) return target ? "Scrolled it into view; the page itself doesn’t scroll." : "The page doesn’t scroll.";
		const moved = at - Math.round(before);
		const where = `At ${at} of ${most} px`;
		if (moved !== 0) return `${where} (moved ${moved > 0 ? "down" : "up"} ${Math.abs(moved)}).`;
		if (at >= most - 1) return `Already at the bottom (${most} px).`;
		if (at <= 0) return `Already at the top (of ${most} px).`;
		return `${where}; it didn’t move.`;
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
			case "outline": return outline(document, args.after ?? -1);
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
			case "scroll": return scroll(target, args);
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
			case "find-field": {
				const n = findField(args.label ?? "");
				return n === null ? null : String(n);
			}
			case "kind": return kindOf(target);
			case "tables": return tables();
			case "problems": return problems();
			case "attach": return attach(target, args.files ?? []);
			case "selection": return window.getSelection()?.toString() ?? "";
			case "code": {
				const field = document.querySelector("input[autocomplete=\"one-time-code\"], input[name*=\"otp\" i], input[name*=\"code\" i][inputmode=\"numeric\"]");
				return field ? write(field, args.text ?? "", "replace") : "nowhere";
			}
			default: return "unknown";
		}
	}

//#endregion
exports.attach = attach;
exports.check = check;
exports.choose = choose;
exports.describe = describe;
exports.find = find;
exports.findField = findField;
exports.kindOf = kindOf;
exports.labelOf = labelOf;
exports.outline = outline;
exports.place = place;
exports.problems = problems;
exports.readField = readField;
exports.run = run;
exports.scroll = scroll;
exports.shownValue = shownValue;
exports.tables = tables;
exports.write = write;
return exports;
})({});