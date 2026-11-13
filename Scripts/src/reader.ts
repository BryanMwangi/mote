// Reading mode: replaces the page with its main article.
// Called from Swift (Reader.swift), which reads the returned value.

import { articleTitle, cleanArticle, findArticle, OVERLAYS, resolveImages, siteName } from './reader/article';
import { READER_ID, READER_STYLE } from './reader/style';

export type ReaderResult = 'read' | 'none';

export function run(): ReaderResult {
  const article = findArticle(document);
  if (!article) return 'none';

  resolveImages(article);
  const title = articleTitle(document);

  const container = document.createElement('div');
  container.id = READER_ID;
  container.innerHTML = article.innerHTML;
  cleanArticle(container);

  const heading = document.createElement('h1');
  heading.textContent = title;
  const source = document.createElement('p');
  source.className = 'mote-from';
  source.textContent = siteName(location.host);
  container.prepend(heading, source);

  const style = document.createElement('style');
  style.textContent = READER_STYLE;

  document.body.replaceChildren(container);
  document.head.append(style);
  window.scrollTo(0, 0);
  return 'read';
}

/**
 * The article's text, read without changing the page: the same scoring as
 * reading mode finds the article, but it is cleaned on a copy, so the page the
 * person is looking at stays where it is. Falls back to the page's whole text
 * when nothing reads like an article.
 */
export function text(): string {
  const article = findArticle(document);
  let read = '';
  if (article) {
    const copy = article.cloneNode(true) as Element;
    cleanArticle(copy);
    read = tidy(copy.textContent ?? '');
  }
  // An app's page reads as little prose: then all of it, without what's over it.
  if (read.length >= 200 || !document.body) return read;
  const page = document.body.cloneNode(true) as HTMLElement;
  for (const overlay of page.querySelectorAll(OVERLAYS)) overlay.remove();
  for (const noise of page.querySelectorAll('script, style, noscript, template')) noise.remove();
  const whole = tidy(page.innerText || page.textContent || '');
  return whole.length > read.length ? whole : read;
}

function tidy(words: string): string {
  return words
    .replace(/[ \t]+/g, ' ')
    .replace(/(\n\s*){3,}/g, '\n\n')
    .trim();
}
