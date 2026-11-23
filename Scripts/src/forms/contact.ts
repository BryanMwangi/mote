// Contact fields: which ask for a name, an email, a phone or an address, and
// filling them from the person's card in Contacts when they pick it (forms.ts).

import { hasSize, setFieldValue } from './sign-in';

/** What a contact field asks for, as the person's card has it. */
export type ContactPart =
  | 'name'
  | 'given'
  | 'family'
  | 'email'
  | 'tel'
  | 'street'
  | 'city'
  | 'region'
  | 'postal'
  | 'country'
  | 'organization';

/** The card, part by part; missing parts aren't filled. */
export type ContactCard = Partial<Record<ContactPart, string>>;

/** The page's own `autocomplete` tokens, the plain way to say what a field wants. */
const TOKENS: Record<string, ContactPart> = {
  name: 'name',
  'given-name': 'given',
  'family-name': 'family',
  email: 'email',
  tel: 'tel',
  'tel-national': 'tel',
  'street-address': 'street',
  'address-line1': 'street',
  'address-level2': 'city',
  'address-level1': 'region',
  'postal-code': 'postal',
  country: 'country',
  'country-name': 'country',
  organization: 'organization',
};

/** Else, what the field is called, by its name, id, placeholder or label. */
const WORDS: [RegExp, ContactPart][] = [
  [/first.?name|given.?name|forename|vorname|prénom/i, 'given'],
  [/last.?name|family.?name|surname|nachname/i, 'family'],
  [/e.?mail/i, 'email'],
  [/phone|mobile|tel\b|telephone/i, 'tel'],
  [/post.?code|zip|postal/i, 'postal'],
  [/city|town/i, 'city'],
  [/state|province|county|region/i, 'region'],
  [/country/i, 'country'],
  [/address|street/i, 'street'],
  [/company|organi[sz]ation|employer/i, 'organization'],
  [/full.?name|your.?name|^name$/i, 'name'],
];

function described(field: HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement): string {
  const label = field.labels?.[0]?.textContent ?? field.getAttribute('aria-label') ?? '';
  const placeholder = 'placeholder' in field ? field.placeholder : '';
  return [field.name, field.id, placeholder, label].join(' ');
}

/** What a field asks for of the person's details, or null. Never a password. */
export function contactPart(element: Element | null): ContactPart | null {
  if (
    !(
      element instanceof HTMLInputElement ||
      element instanceof HTMLSelectElement ||
      element instanceof HTMLTextAreaElement
    )
  ) {
    return null;
  }
  if (element instanceof HTMLInputElement && !['text', 'email', 'tel', 'search', ''].includes(element.type))
    return null;
  for (const token of (element.getAttribute('autocomplete') ?? '').toLowerCase().split(/\s+/)) {
    if (token === 'off' || token === 'new-password' || token === 'current-password') continue;
    if (TOKENS[token]) return TOKENS[token]!;
  }
  if (element instanceof HTMLInputElement && element.type === 'email') return 'email';
  if (element instanceof HTMLInputElement && element.type === 'tel') return 'tel';
  const words = described(element);
  return WORDS.find(([pattern]) => pattern.test(words))?.[1] ?? null;
}

/** A field's value from the card: a full name split where the page asks for parts. */
function valueFor(part: ContactPart, card: ContactCard): string | undefined {
  if (part === 'name') return card.name ?? [card.given, card.family].filter(Boolean).join(' ');
  return card[part];
}

/**
 * Fills the empty contact fields around `focused` (its form, else the page)
 * from the card, as typing would; how many it filled.
 */
export function fillContact(focused: Element | null, card: ContactCard): number {
  const scope = focused?.closest('form') ?? document;
  let filled = 0;
  for (const field of scope.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>(
    'input, select, textarea',
  )) {
    if (field.disabled || ('readOnly' in field && field.readOnly) || !hasSize(field) || field.value) continue;
    const part = contactPart(field);
    const value = part ? valueFor(part, card) : undefined;
    if (!value) continue;
    if (field instanceof HTMLSelectElement) {
      const wanted = value.toLowerCase();
      const option = [...field.options].find(
        (item) => item.text.trim().toLowerCase() === wanted || item.value.toLowerCase() === wanted,
      );
      if (!option) continue;
      field.value = option.value;
      field.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (field instanceof HTMLInputElement) {
      setFieldValue(field, value);
    } else {
      field.value = value;
      field.dispatchEvent(new Event('input', { bubbles: true }));
    }
    filled++;
  }
  return filled;
}
