// Generated from Scripts/src/forms.ts by `pnpm build`. Do not edit.
(function() {

//#region src/forms/sign-in.ts
/** Input types that can hold the account name next to a password. */
	const USERNAME_TYPES = /* @__PURE__ */ new Set([
		"text",
		"email",
		"tel"
	]);
	/** The lowercase type of an input, `text` when it has none. */
	function inputType(input) {
		return (input.type || "text").toLowerCase();
	}
	/** Whether an element takes up any room on the page (hidden ones don't). */
	function hasSize(element) {
		const rect = element.getBoundingClientRect();
		return rect.width > 0 && rect.height > 0;
	}
	/** Fields seen as password fields. */
	const passwords = /* @__PURE__ */ new WeakSet();
	/**
	* Whether a field is a password field, or was one when last seen: a site
	* that shows the password turns its field into a text field, and it is still
	* the password.
	*/
	function isPassword(input) {
		if (inputType(input) !== "password") return passwords.has(input);
		passwords.add(input);
		return true;
	}
	/** Whether a field could hold the account's name. */
	function takesName(input) {
		return USERNAME_TYPES.has(inputType(input)) && !isPassword(input);
	}
	/** Whether a field looks like the one an account's name goes in, with or without a password field by it. */
	function isNameField(input) {
		if (!takesName(input)) return false;
		return inputType(input) === "email" || /user|login|email/i.test(`${input.autocomplete} ${input.name} ${input.id}`);
	}
	/**
	* The page's sign-in, or null when it has none: the first password field that
	* is shown, and the last field before it (in its form, or the document) that
	* could hold a name.
	*/
	function signInFields(document) {
		let password = null;
		for (const field of document.querySelectorAll("input")) if (isPassword(field) && hasSize(field)) {
			password = field;
			break;
		}
		if (!password) return null;
		const scope = password.form || password.closest("form") || document;
		let user = null;
		for (const input of scope.querySelectorAll("input")) {
			if (input === password) break;
			if (takesName(input)) user = input;
		}
		return {
			user,
			password
		};
	}
	/**
	* Sets a field's value as typing would. The native setter and the input and
	* change events are what frameworks such as React notice; assigning `.value`
	* alone is not.
	*/
	function setFieldValue(field, value) {
		const descriptor = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value");
		if (descriptor && descriptor.set) descriptor.set.call(field, value);
		else field.value = value;
		field.dispatchEvent(new Event("input", { bubbles: true }));
		field.dispatchEvent(new Event("change", { bubbles: true }));
	}
	/**
	* Fills a saved account the user picked: the name only into an empty name
	* field, the password always. False when the page has no sign-in anymore.
	*/
	function fillSignIn(fields, user, password) {
		if (!fields) return false;
		if (fields.user && !fields.user.value) setFieldValue(fields.user, user);
		setFieldValue(fields.password, password);
		return true;
	}
	/**
	* Fills a saved account from the field its menu opened on: a password field
	* takes the password, and the empty name field before it the name; a name
	* field takes the name, and the password field after it the password. Within
	* the field's form, or the document. Null when the field is gone, `name` when
	* there was no password field to fill.
	*/
	function fillAround(field, user, password) {
		if (!field || !field.isConnected) return null;
		const inputs = [...(field.form || field.closest("form") || document).querySelectorAll("input")];
		const at = inputs.indexOf(field);
		if (isPassword(field)) {
			const name = inputs.slice(0, at).findLast(takesName);
			if (name && !name.value) setFieldValue(name, user);
			setFieldValue(field, password);
			return "all";
		}
		setFieldValue(field, user);
		const next = inputs.slice(at + 1).find((input) => isPassword(input) && hasSize(input));
		if (!next) return "name";
		setFieldValue(next, password);
		return "all";
	}
	/** What a sign-in is about to send, or null while its password is empty. */
	function submittedCredentials(fields) {
		if (!fields || !fields.password.value) return null;
		return {
			user: fields.user ? fields.user.value : "",
			password: fields.password.value
		};
	}
	/**
	* A new password, into `field` and the empty password fields after it in its
	* form, which ask for it again (one before it is the current password). A
	* field that takes fewer characters gets it without its hyphens, cut short.
	* What went in, or null when the field is gone.
	*/
	function fillNewPassword(field, password) {
		if (!field || !field.isConnected) return null;
		const room = field.maxLength;
		const fitted = room > 0 && password.length > room ? password.replaceAll("-", "").slice(0, room) : password;
		setFieldValue(field, fitted);
		const fields = [...(field.form ?? document).querySelectorAll("input")].filter(isPassword);
		for (const other of fields.slice(fields.indexOf(field) + 1)) if (!other.value && !other.readOnly && !other.disabled) setFieldValue(other, fitted);
		return fitted;
	}

//#endregion
//#region src/forms/contact.ts
/** The page's own `autocomplete` tokens, the plain way to say what a field wants. */
	const TOKENS = {
		name: "name",
		"given-name": "given",
		"family-name": "family",
		email: "email",
		tel: "tel",
		"tel-national": "tel",
		"street-address": "street",
		"address-line1": "street",
		"address-level2": "city",
		"address-level1": "region",
		"postal-code": "postal",
		country: "country",
		"country-name": "country",
		organization: "organization"
	};
	/** Else, what the field is called, by its name, id, placeholder or label. */
	const WORDS = [
		[/first.?name|given.?name|forename|vorname|prénom/i, "given"],
		[/last.?name|family.?name|surname|nachname/i, "family"],
		[/e.?mail/i, "email"],
		[/phone|mobile|tel\b|telephone/i, "tel"],
		[/post.?code|zip|postal/i, "postal"],
		[/city|town/i, "city"],
		[/state|province|county|region/i, "region"],
		[/country/i, "country"],
		[/address|street/i, "street"],
		[/company|organi[sz]ation|employer/i, "organization"],
		[/full.?name|your.?name|^name$/i, "name"]
	];
	function described(field) {
		const label = field.labels?.[0]?.textContent ?? field.getAttribute("aria-label") ?? "";
		const placeholder = "placeholder" in field ? field.placeholder : "";
		return [
			field.name,
			field.id,
			placeholder,
			label
		].join(" ");
	}
	/** What a field asks for of the person's details, or null. Never a password. */
	function contactPart(element) {
		if (!(element instanceof HTMLInputElement || element instanceof HTMLSelectElement || element instanceof HTMLTextAreaElement)) return null;
		if (element instanceof HTMLInputElement && ![
			"text",
			"email",
			"tel",
			"search",
			""
		].includes(element.type)) return null;
		for (const token of (element.getAttribute("autocomplete") ?? "").toLowerCase().split(/\s+/)) {
			if (token === "off" || token === "new-password" || token === "current-password") continue;
			if (TOKENS[token]) return TOKENS[token];
		}
		if (element instanceof HTMLInputElement && element.type === "email") return "email";
		if (element instanceof HTMLInputElement && element.type === "tel") return "tel";
		const words = described(element);
		return WORDS.find(([pattern]) => pattern.test(words))?.[1] ?? null;
	}
	/** A field's value from the card: a full name split where the page asks for parts. */
	function valueFor(part, card) {
		if (part === "name") return card.name ?? [card.given, card.family].filter(Boolean).join(" ");
		return card[part];
	}
	/**
	* Fills the empty contact fields around `focused` (its form, else the page)
	* from the card, as typing would; how many it filled.
	*/
	function fillContact(focused, card) {
		const scope = focused?.closest("form") ?? document;
		let filled = 0;
		for (const field of scope.querySelectorAll("input, select, textarea")) {
			if (field.disabled || "readOnly" in field && field.readOnly || !hasSize(field) || field.value) continue;
			const part = contactPart(field);
			const value = part ? valueFor(part, card) : void 0;
			if (!value) continue;
			if (field instanceof HTMLSelectElement) {
				const wanted = value.toLowerCase();
				const option = [...field.options].find((item) => item.text.trim().toLowerCase() === wanted || item.value.toLowerCase() === wanted);
				if (!option) continue;
				field.value = option.value;
				field.dispatchEvent(new Event("change", { bubbles: true }));
			} else if (field instanceof HTMLInputElement) setFieldValue(field, value);
			else {
				field.value = value;
				field.dispatchEvent(new Event("input", { bubbles: true }));
			}
			filled++;
		}
		return filled;
	}
	/**
	* What a form being sent holds of the person's details, part by part, or
	* null when it holds no name, or nothing to reach them by besides. Never
	* from a form with a password: that's a sign-in.
	*/
	function contactSent(form) {
		if (form.querySelector("input[type=password]")) return null;
		const card = {};
		for (const field of form.querySelectorAll("input, select, textarea")) {
			const part = contactPart(field);
			const value = field instanceof HTMLSelectElement ? field.options[field.selectedIndex]?.text.trim() ?? "" : field.value.trim();
			if (part && value && !card[part]) card[part] = value.slice(0, 200);
		}
		return (card.name || card.given || card.family) && (card.email || card.tel || card.street) ? card : null;
	}

//#endregion
//#region src/forms/typing.ts
/** How many fields typed into are remembered, the oldest forgotten first. */
	const MAX_TYPED_FIELDS = 40;
	/** Input types whose text is worth keeping a page awake for. */
	const TEXT_TYPES = /* @__PURE__ */ new Set([
		"text",
		"email",
		"url",
		"tel",
		"number"
	]);
	/** Input types that take typing at the caret, so Tab stays with the page. */
	const TYPING_TYPES = /* @__PURE__ */ new Set([
		"text",
		"search",
		"email",
		"url",
		"tel",
		"password",
		"number",
		"date",
		"datetime-local",
		"month",
		"week",
		"time"
	]);
	function tagName(element) {
		return (element.tagName || "").toLowerCase();
	}
	function changedText(element) {
		return !!(element.value || "").trim() && element.value !== element.defaultValue;
	}
	/**
	* Whether a field typed into by hand still holds text that wasn't sent. A
	* field emptied by sending (a chat's composer) no longer does, and neither
	* does a search field.
	*/
	function holdsUnsentText(element) {
		if (!element.isConnected) return false;
		const tag = tagName(element);
		if (tag === "textarea") return changedText(element);
		if (tag === "input") {
			if (!TEXT_TYPES.has((element.type || "text").toLowerCase())) return false;
			return changedText(element);
		}
		if (element.isContentEditable) return !!(element.textContent || "").trim();
		return false;
	}
	/**
	* The fields typed into by hand. A page whose fields still hold what was typed
	* is not put to sleep: waking it couldn't bring that back.
	*/
	var TypedFields = class {
		fields = [];
		/** Remembers the field an input event came from. */
		record(event) {
			if (!event.isTrusted) return;
			const field = event.target;
			if (!field || this.fields.includes(field)) return;
			this.fields.push(field);
			if (this.fields.length > 40) this.fields.shift();
		}
		/** Whether any of them holds text that wasn't sent. */
		unsaved() {
			return this.fields.some((field) => holdsUnsentText(field));
		}
	};
	/**
	* Whether the caret is somewhere on the page that takes typing.
	*
	* The browser gives Tab to its own row of tabs, which is right until you are
	* filling something in: plenty of fields offer a completion you take with Tab,
	* and stealing the key there would make them unusable.
	*/
	function acceptsTyping(element) {
		if (!element) return false;
		const tag = tagName(element);
		if (tag === "textarea") return true;
		if (element.isContentEditable === true) return true;
		if (element.getAttribute && element.getAttribute("role") === "textbox") return true;
		if (tag === "iframe") {
			if (!sameOrigin(element)) return false;
			try {
				const inner = element.contentDocument;
				return acceptsTyping(inner && inner.activeElement);
			} catch {
				return false;
			}
		}
		if (tag !== "input") return false;
		return TYPING_TYPES.has((element.type || "text").toLowerCase());
	}
	/** Whether a frame's document is this page's origin, judged without touching it. */
	function sameOrigin(frame) {
		try {
			const url = new URL(frame.getAttribute("src") || "about:blank", location.href);
			if (url.protocol === "about:") return !frame.hasAttribute("sandbox") || frame.sandbox.contains("allow-same-origin");
			return url.origin === location.origin;
		} catch {
			return false;
		}
	}
	/** A field's frame in the viewport, in CSS pixels, or null while it takes no room. */
	function fieldFrame(element) {
		const rect = element.getBoundingClientRect();
		if (rect.width > 0 && rect.height > 0) return {
			x: rect.left,
			y: rect.top,
			w: rect.width,
			h: rect.height
		};
		return null;
	}

//#endregion
//#region src/forms.ts
/** Once the sign-in fields are gone, how long they must stay gone for a sign-in done in place. */
	const SETTLE_MS = 400;
	/** When to look again for a sign-in the page builds itself, or the password step after the name. */
	const LATE_FORM_CHECKS_MS = [700, 2200];
	function post(message) {
		window.webkit.messageHandlers.moteForms?.postMessage(message);
	}
	function findSignIn() {
		return signInFields(document);
	}
	/**
	* What is in the fields when they are sent. Said every time (a click on "show
	* password" says it too) because Swift only listens once the page has moved
	* on, and keeps the last thing it heard.
	*/
	function offer() {
		const sent = submittedCredentials(findSignIn());
		if (sent) post({
			kind: "submit",
			user: sent.user,
			password: sent.password
		});
	}
	/** The last caret report, so the same one isn't sent twice. */
	let reported = "";
	/** Whether the caret is in a sign-in field, whose frame moves with the page. */
	let hanging = false;
	/** Where the caret is, and the frame of the sign-in field it's in, which the account list hangs from. */
	function caret() {
		const focused = document.activeElement;
		const fields = findSignIn();
		const inSignIn = fields && focused && (focused === fields.user || focused === fields.password);
		const rect = inSignIn && focused ? fieldFrame(focused) : null;
		const contact = !inSignIn && contactPart(focused) ? fieldFrame(focused) : null;
		hanging = rect !== null || contact !== null;
		const message = {
			kind: "focus",
			typing: acceptsTyping(focused),
			rect,
			contact
		};
		const said = JSON.stringify(message);
		if (said === reported) return;
		reported = said;
		post(message);
	}
	/**
	* Full screen, on or off, as the page hears it. Swift learns of going full
	* screen earlier from the web view itself (FormRelay.watchFullscreen): the
	* page's own requestFullscreen can't be seen from this world, and nothing
	* patched here could be without the page seeing it too.
	*/
	function immersed() {
		const webkitElement = document.webkitFullscreenElement;
		post({
			kind: "fullscreen",
			on: !!(document.fullscreenElement || webkitElement)
		});
	}
	if (!window.__moteForms) installForms();
	function installForms() {
		const typed = new TypedFields();
		document.addEventListener("input", (event) => typed.record(event), true);
		window.__moteForms = {
			unsaved: () => typed.unsaved(),
			fill: (user, password, menu) => menu ? fillAround(menuField, user, password) !== null : fillSignIn(findSignIn(), user, password),
			hasPassword: () => !!findSignIn(),
			suggest: (password) => fillNewPassword(menuField, password),
			contact: (card) => fillContact(document.activeElement, card)
		};
		let menuField = null;
		document.addEventListener("contextmenu", (event) => {
			const target = event.composedPath()[0];
			menuField = target instanceof HTMLInputElement && !target.readOnly && !target.disabled ? target : null;
			const field = !menuField ? null : isPassword(menuField) ? "password" : isNameField(menuField) || menuField === findSignIn()?.user ? "user" : null;
			if (!field) menuField = null;
			post({
				kind: "menu",
				field
			});
		}, true);
		document.addEventListener("submit", offer, true);
		let toldCard = "";
		const sentCard = (form) => {
			const card = contactSent(form);
			const said = JSON.stringify(card);
			if (!card || said === toldCard) return;
			toldCard = said;
			post({
				kind: "contact",
				card
			});
		};
		document.addEventListener("submit", (event) => sentCard(event.target instanceof Element ? event.target : document), true);
		document.addEventListener("keydown", (event) => {
			if (event.key !== "Enter") return;
			const fields = findSignIn();
			const focused = document.activeElement;
			if (fields && (focused === fields.password || focused === fields.user)) offer();
		}, true);
		document.addEventListener("click", (event) => {
			const target = event.target;
			if (!target || !target.closest) return;
			const button = target.closest("button, input[type=\"submit\"], [role=\"button\"]");
			if (!button) return;
			setTimeout(offer, 0);
			const form = button.closest("form");
			if (form) setTimeout(() => sentCard(form), 0);
		}, true);
		let told = false;
		const tell = () => {
			if (told || !findSignIn()) return;
			told = true;
			post({ kind: "form" });
		};
		if (document.readyState === "complete") tell();
		else window.addEventListener("load", tell);
		for (const delay of LATE_FORM_CHECKS_MS) setTimeout(tell, delay);
		let settling;
		new MutationObserver(() => {
			if (!told) {
				tell();
				return;
			}
			if (findSignIn()) return;
			told = false;
			clearTimeout(settling);
			settling = setTimeout(() => {
				if (!findSignIn()) post({ kind: "settled" });
			}, SETTLE_MS);
		}).observe(document.documentElement, {
			childList: true,
			subtree: true
		});
		let moving = false;
		const moved = () => {
			if (moving || !hanging) return;
			moving = true;
			requestAnimationFrame(() => {
				moving = false;
				caret();
			});
		};
		window.addEventListener("scroll", moved, true);
		window.addEventListener("resize", moved);
		document.addEventListener("fullscreenchange", immersed, true);
		document.addEventListener("webkitfullscreenchange", immersed, true);
		document.addEventListener("focusin", caret, true);
		document.addEventListener("focusout", () => setTimeout(caret, 0), true);
		document.addEventListener("mouseup", () => setTimeout(caret, 0), true);
		caret();
	}

//#endregion
})();