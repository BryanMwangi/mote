import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { check, choose, find, outline, readField, run, tables, write } from '../src/assistant-page';

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
