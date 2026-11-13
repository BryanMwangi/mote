/** Input types that can hold the account name next to a password. */
const USERNAME_TYPES = new Set(['text', 'email', 'tel']);

/** A sign-in on the page: its password field and the field that names the account, if any. */
export interface SignInFields {
  user: HTMLInputElement | null;
  password: HTMLInputElement;
}

/** The lowercase type of an input, `text` when it has none. */
export function inputType(input: HTMLInputElement): string {
  return (input.type || 'text').toLowerCase();
}

/** Whether an element takes up any room on the page (hidden ones don't). */
export function hasSize(element: Element): boolean {
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

/** Fields seen as password fields. */
const passwords = new WeakSet<HTMLInputElement>();

/**
 * Whether a field is a password field, or was one when last seen: a site
 * that shows the password turns its field into a text field, and it is still
 * the password.
 */
export function isPassword(input: HTMLInputElement): boolean {
  if (inputType(input) !== 'password') return passwords.has(input);
  passwords.add(input);
  return true;
}

/** Whether a field could hold the account's name. */
function takesName(input: HTMLInputElement): boolean {
  return USERNAME_TYPES.has(inputType(input)) && !isPassword(input);
}

/** Whether a field looks like the one an account's name goes in, with or without a password field by it. */
export function isNameField(input: HTMLInputElement): boolean {
  if (!takesName(input)) return false;
  return (
    inputType(input) === 'email' ||
    /user|login|email/i.test(`${input.autocomplete} ${input.name} ${input.id}`)
  );
}

/**
 * The page's sign-in, or null when it has none: the first password field that
 * is shown, and the last field before it (in its form, or the document) that
 * could hold a name.
 */
export function signInFields(document: Document): SignInFields | null {
  let password: HTMLInputElement | null = null;
  for (const field of document.querySelectorAll('input')) {
    if (isPassword(field) && hasSize(field)) {
      password = field;
      break;
    }
  }
  if (!password) return null;
  const scope: ParentNode = password.form || password.closest('form') || document;
  let user: HTMLInputElement | null = null;
  for (const input of scope.querySelectorAll('input')) {
    if (input === password) break;
    if (takesName(input)) user = input;
  }
  return { user, password };
}

/**
 * Sets a field's value as typing would. The native setter and the input and
 * change events are what frameworks such as React notice; assigning `.value`
 * alone is not.
 */
export function setFieldValue(field: HTMLInputElement, value: string): void {
  const descriptor = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
  if (descriptor && descriptor.set) descriptor.set.call(field, value);
  else field.value = value;
  field.dispatchEvent(new Event('input', { bubbles: true }));
  field.dispatchEvent(new Event('change', { bubbles: true }));
}

/**
 * Fills a saved account the user picked: the name only into an empty name
 * field, the password always. False when the page has no sign-in anymore.
 */
export function fillSignIn(fields: SignInFields | null, user: string, password: string): boolean {
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
export function fillAround(
  field: HTMLInputElement | null,
  user: string,
  password: string,
): 'all' | 'name' | null {
  if (!field || !field.isConnected) return null;
  const inputs = [...(field.form || field.closest('form') || document).querySelectorAll('input')];
  const at = inputs.indexOf(field);
  if (isPassword(field)) {
    const name = inputs.slice(0, at).findLast(takesName);
    if (name && !name.value) setFieldValue(name, user);
    setFieldValue(field, password);
    return 'all';
  }
  setFieldValue(field, user);
  const next = inputs.slice(at + 1).find((input) => isPassword(input) && hasSize(input));
  if (!next) return 'name';
  setFieldValue(next, password);
  return 'all';
}

/** What a sign-in is about to send, or null while its password is empty. */
export function submittedCredentials(fields: SignInFields | null): { user: string; password: string } | null {
  if (!fields || !fields.password.value) return null;
  return { user: fields.user ? fields.user.value : '', password: fields.password.value };
}

/**
 * A new password, into `field` and the empty password fields after it in its
 * form, which ask for it again (one before it is the current password). A
 * field that takes fewer characters gets it without its hyphens, cut short.
 * What went in, or null when the field is gone.
 */
export function fillNewPassword(field: HTMLInputElement | null, password: string): string | null {
  if (!field || !field.isConnected) return null;
  const room = field.maxLength;
  const fitted = room > 0 && password.length > room ? password.replaceAll('-', '').slice(0, room) : password;
  setFieldValue(field, fitted);
  const fields = [...(field.form ?? document).querySelectorAll('input')].filter(isPassword);
  for (const other of fields.slice(fields.indexOf(field) + 1)) {
    if (!other.value && !other.readOnly && !other.disabled) setFieldValue(other, fitted);
  }
  return fitted;
}
