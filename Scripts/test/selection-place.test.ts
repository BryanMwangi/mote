import { describe, expect, it } from 'vitest';
import { selectionPlace } from '../src/selected-text/place';

function select(html: string, selector: string, word: string) {
  document.body.innerHTML = html;
  const node = document.querySelector(selector)!.firstChild!;
  const at = node.textContent!.indexOf(word);
  const range = document.createRange();
  range.setStart(node, at);
  range.setEnd(node, at + word.length);
  getSelection()!.removeAllRanges();
  getSelection()!.addRange(range);
}

describe('selectionPlace', () => {
  it('gives the passage the selection is in and the heading over it', () => {
    select(
      '<h1>Lyon</h1><h2>Economy</h2><p id="p">Lyon is historically an industrial city with a large chemical valley.</p><h2>Later</h2>',
      '#p',
      'chemical valley',
    );
    expect(selectionPlace(document)).toEqual({
      around: 'Lyon is historically an industrial city with a large chemical valley.',
      heading: 'Economy',
    });
  });

  it('cuts a long passage around the selection', () => {
    const long = `${'a '.repeat(600)}needle ${'b '.repeat(600)}`;
    select(`<p id="p">${long}</p>`, '#p', 'needle');
    const place = selectionPlace(document)!;
    expect(place.around).toContain('needle');
    expect(place.around.length).toBeLessThan(610);
    expect(place.around.startsWith('…') && place.around.endsWith('…')).toBe(true);
    expect(place.heading).toBe('');
  });

  it('is null with nothing selected', () => {
    document.body.innerHTML = '<p>Text</p>';
    getSelection()!.removeAllRanges();
    expect(selectionPlace(document)).toBeNull();
  });
});
