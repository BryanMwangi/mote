import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  attach,
  check,
  choose,
  find,
  outline,
  problems,
  readField,
  run,
  tables,
  write,
} from '../src/assistant-page';

beforeEach(() => {
  vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function (this: Element) {
    return new DOMRect(10, 20, this.hasAttribute('data-hidden') ? 0 : 100, 20);
  });
  delete window.__moteOutline;
});

afterEach(() => {
  vi.restoreAllMocks();
  document.body.innerHTML = '';
});

const byId = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

describe('outline', () => {
  it('numbers what can be picked, and keeps the numbers as the page grows', () => {
    document.body.innerHTML = '<button id="a">Save</button><a id="b" href="/x">More</a><span>text</span>';
    expect(outline()).toBe('[0] button(submit) Save\n[1] a More -> http://localhost:3000/x');
    const added = document.createElement('input');
    added.placeholder = 'Search';
    document.body.prepend(added);
    const again = outline();
    expect(again).toContain('[0] button(submit) Save');
    expect(again).toContain('[2] input(text) Search');
  });

  it('leaves out what takes no room, and says whether boxes are ticked', () => {
    document.body.innerHTML =
      '<button data-hidden>Gone</button><input type="checkbox" id="c" checked aria-label="Agree">';
    expect(outline()).toBe('[1] input(checkbox) Agree [on]');
  });
});

describe('fields in the outline', () => {
  it('names a field by its label, hidden or not, and says what it holds', () => {
    document.body.innerHTML = `
      <label for="e" style="position:absolute;clip:rect(0 0 0 0)">Email address</label><input id="e" placeholder="you@…" value="ana@x.io">
      <span id="cl">Cover letter</span><textarea aria-labelledby="cl"></textarea>
      <fieldset><legend>Salary</legend><input name="sal" value="5000"></fieldset>`;
    const list = outline();
    expect(list).toContain('input(text) Email address = "ana@x.io"');
    expect(list).toContain('textarea(textarea) Cover letter = (empty)');
    expect(list).toContain('input(text) Salary = "5000"');
  });

  it('shows a list by its chosen option, and its value when the option says nothing', () => {
    document.body.innerHTML = `
      <label>Country <select id="c" required><option value="">Pick one</option><option value="KE"></option></select></label>`;
    const select = byId<HTMLSelectElement>('c');
    expect(outline()).toContain('select(select-one) Country = "Pick one" (required, invalid');
    select.value = 'KE';
    expect(outline()).toBe('[0] select(select-one) Country = "KE" (required)');
  });

  it('lists what the page would refuse to send', () => {
    document.body.innerHTML = `
      <input aria-label="Name" required><input aria-label="Phone" value="1" aria-invalid="true"><input aria-label="City" value="Nairobi" required>`;
    const found = problems();
    expect(found).toHaveLength(2);
    expect(found[0]).toContain('Name = (empty) (required');
    expect(found[1]).toContain('Phone = "1" (invalid)');
  });

  it('never shows a password', () => {
    document.body.innerHTML = '<input type="password" aria-label="Password" value="secret">';
    expect(outline()).toBe('[0] input(password) Password = "••••"');
  });
});

// As Angular Material does: the options appear in an overlay at the end of the body.
const overlay = (names: string[], chosen: (name: string) => void) => {
  const panel = document.createElement('div');
  panel.id = 'panel';
  panel.setAttribute('role', 'listbox');
  for (const name of names) {
    const option = document.createElement('div');
    option.setAttribute('role', 'option');
    option.textContent = ` ${name} `;
    option.addEventListener('click', () => chosen(name));
    panel.append(option);
  }
  document.body.append(panel);
};

describe('dropdowns a page draws itself', () => {
  it('lists them with their state, and opens one to pick an option', async () => {
    document.body.innerHTML = `
      <span id="l">Country</span>
      <div id="s" role="combobox" aria-labelledby="l" aria-controls="panel" aria-expanded="false"><span id="t">Select</span></div>`;
    const select = byId('s');
    let got = '';
    // Where a pointer lands: the inner trigger, which is what listens.
    vi.spyOn(document, 'elementFromPoint').mockImplementation(() => byId('t'));
    byId('t').addEventListener('click', () => {
      select.setAttribute('aria-expanded', 'true');
      overlay(['Germany', 'Kenya'], (name) => (got = name));
    });
    expect(outline()).toBe('[0] combobox Country = "Select"');
    expect(await run('choose', { n: 0, value: 'kenya' })).toBe('done');
    expect(got).toBe('Kenya');
    expect(outline()).toContain('[0] combobox Country = "Select" [open]');
  });

  it('types into an autocomplete to bring its options up', async () => {
    document.body.innerHTML = '<input id="a" role="combobox" aria-label="City">';
    let got = '';
    byId('a').addEventListener('input', (event) => {
      if ((event.target as HTMLInputElement).value === 'Nai')
        overlay(['Nairobi', 'Naivasha'], (name) => (got = name));
    });
    expect(outline()).toBe('[0] combobox City = (empty)');
    expect(run('kind', { n: 0 })).toBe('select');
    expect(await choose(byId('a'), 'Nai')).toBe('done');
    expect(got).toBe('Nairobi');
  });

  it('says which options there are when none matches', async () => {
    document.body.innerHTML = '<div id="s" role="combobox" aria-label="Size">M</div>';
    byId('s').addEventListener('click', () => overlay(['Small', 'Large'], () => {}));
    expect(await choose(byId('s'), 'Huge')).toBe('no-option: Small | Large');
  });
});

describe('attach', () => {
  const cv = { name: 'cv.pdf', type: 'application/pdf', data: btoa('%PDF-1.4') };

  it('lists a hidden file field, and puts files in through the button over it', () => {
    document.body.innerHTML = `
      <div><button id="b">Upload CV</button><input id="f" type="file" data-hidden aria-label="CV" required></div>`;
    expect(outline()).toContain('[0] button(submit) Upload CV\n[1] input(file) CV = (empty) (required');
    const heard: string[] = [];
    byId('f').addEventListener('change', () => heard.push('change'));
    expect(attach(byId('b'), [cv])).toBe('done');
    expect(byId<HTMLInputElement>('f').files?.[0]?.name).toBe('cv.pdf');
    expect(heard).toEqual(['change']);
    expect(outline()).toContain('CV = "cv.pdf"');
  });

  it('takes one file where the field takes one', () => {
    document.body.innerHTML = '<input id="f" type="file">';
    expect(attach(byId('f'), [cv, cv])).toBe('one-file-only');
    outline();
    expect(run('kind', { n: 0 })).toBe('file');
  });
});

describe('scroll', () => {
  it('says where the page is, how far it moved, and when it does not scroll', async () => {
    const page = document.scrollingElement as HTMLElement;
    let top = 0;
    vi.spyOn(page, 'scrollHeight', 'get').mockReturnValue(3000);
    vi.spyOn(page, 'clientHeight', 'get').mockReturnValue(1000);
    vi.spyOn(page, 'scrollTop', 'get').mockImplementation(() => top);
    page.scrollBy = ((options: ScrollToOptions) =>
      (top = Math.min(2000, Math.max(0, top + (options.top ?? 0))))) as never;
    page.scrollTo = ((options: ScrollToOptions) => (top = options.top ?? 0)) as never;
    expect(await run('scroll', { by: 800 })).toBe('At 800 of 2000 px (moved down 800).');
    expect(await run('scroll', { to: 'bottom' })).toBe('At 2000 of 2000 px (moved down 1200).');
    expect(await run('scroll', { by: 500 })).toBe('Already at the bottom (2000 px).');
    vi.restoreAllMocks();
    vi.spyOn(page, 'scrollHeight', 'get').mockReturnValue(500);
    vi.spyOn(page, 'clientHeight', 'get').mockReturnValue(500);
    expect(await run('scroll', { by: 800 })).toBe('The page doesn’t scroll.');
  });
});

describe('write', () => {
  it('replaces, appends and inserts in a field, as typing would', () => {
    document.body.innerHTML = '<input id="f" value="Hello">';
    const field = byId<HTMLInputElement>('f');
    const heard: string[] = [];
    field.addEventListener('input', () => heard.push('input'));
    expect(write(field, ' there', 'append')).toBe('done');
    expect(field.value).toBe('Hello there');
    expect(write(field, 'Bye', 'replace')).toBe('done');
    expect(field.value).toBe('Bye');
    expect(heard.length).toBe(2);
  });

  it('never writes into a password field, nor reads one', () => {
    document.body.innerHTML = '<input id="p" type="password" value="secret">';
    expect(write(byId('p'), 'x')).toBe('password');
    expect(readField(byId('p'))).toBe('password');
  });

  it('writes into an editor', () => {
    document.body.innerHTML = '<div id="e" contenteditable="true">Old</div>';
    expect(write(byId('e'), 'Dear Ana,', 'replace')).toBe('done');
    expect(byId('e').textContent).toContain('Dear Ana,');
  });
});

describe('lists, boxes, finding and tables', () => {
  it('picks an option by its value or its words, and says what there is when it can not', () => {
    document.body.innerHTML =
      '<select id="s"><option value="ke">Kenya</option><option value="ug">Uganda</option></select>';
    expect(choose(byId('s'), 'Uganda')).toBe('done');
    expect(byId<HTMLSelectElement>('s').value).toBe('ug');
    expect(choose(byId('s'), 'Peru')).toBe('no-option: Kenya | Uganda');
  });

  it('ticks a box only when it is not already', () => {
    document.body.innerHTML = '<input type="checkbox" id="c">';
    expect(check(byId('c'), true)).toBe('done');
    expect(byId<HTMLInputElement>('c').checked).toBe(true);
    check(byId('c'), true);
    expect(byId<HTMLInputElement>('c').checked).toBe(true);
  });

  it('finds words with what is around them', () => {
    document.body.innerHTML = '<p>The quarterly revenue grew by twelve percent this year.</p>';
    expect(find('revenue')[0]).toContain('quarterly revenue grew');
    expect(find('absent')).toEqual([]);
  });

  it('reads a table as Markdown', () => {
    document.body.innerHTML =
      '<table><tr><th>Name</th><th>Age</th></tr><tr><td>Ana</td><td>30</td></tr></table>';
    expect(tables()).toBe('| Name | Age |\n| --- | --- |\n| Ana | 30 |');
  });

  it('says an element is gone once the page has lost it', () => {
    document.body.innerHTML = '<button id="a">Go</button>';
    outline();
    byId('a').remove();
    expect(run('click', { n: 0 })).toBe('gone');
  });
});

describe('fields by label', () => {
  it('finds a field by its label, exactly first, and says what kind it is', () => {
    document.body.innerHTML = `
      <label for="n">Full name</label><input id="n">
      <label>Email address <input id="e" type="email"></label>
      <input id="p" type="password" aria-label="Password">
      <select id="s" aria-label="Country"><option>Kenya</option></select>
      <label><input id="c" type="checkbox"> Agree</label>`;
    expect(run('find-field', { label: 'full name' })).toBe('0');
    expect(run('find-field', { label: 'Email' })).toBe('1');
    expect(run('find-field', { label: 'Phone' })).toBeNull();
    expect(run('kind', { n: 1 })).toBe('text');
    expect(run('kind', { n: 2 })).toBe('password');
    expect(run('kind', { n: 3 })).toBe('select');
    expect(run('kind', { n: 4 })).toBe('checkbox');
  });
});
