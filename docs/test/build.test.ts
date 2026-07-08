import { test, expect, beforeAll, setDefaultTimeout } from 'bun:test';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { $ } from 'bun';

setDefaultTimeout(180_000);

const SITE = join(import.meta.dir, '..');
const DIST = join(SITE, 'dist');
const BASE = '/harbor-pack'; // production base (URL prefix), no trailing slash

const TITLES: Record<string, string> = {
  '': 'Harbor Pack',
  installation: 'Installation',
  authentication: 'Authentication',
  configuration: 'Configuration',
  'nebariapp-crd-reference': 'NebariApp CRD Reference',
  'auth-flow': 'Authentication Flow',
  'release-readiness': 'Release Readiness',
};

// Astro emits files at dist/ root (base only prefixes URLs, it does not nest output).
function pagePath(slug: string): string {
  return slug === '' ? join(DIST, 'index.html') : join(DIST, slug, 'index.html');
}
function readPage(slug: string): string {
  return readFileSync(pagePath(slug), 'utf8');
}
function allHtmlFiles(): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.html')) out.push(p);
    }
  };
  walk(DIST);
  return out;
}
function allCss(): string {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.css')) out.push(readFileSync(p, 'utf8'));
    }
  };
  walk(DIST);
  return out.join('\n');
}

beforeAll(async () => {
  await $`bun run build`.cwd(SITE);
});

// Journey 1
test('all 7 pages render at dist root with titles and base-prefixed links', () => {
  for (const [slug, title] of Object.entries(TITLES)) {
    expect(existsSync(pagePath(slug))).toBe(true);
    expect(readPage(slug)).toContain(title);
  }
  // Nav links carry the production base prefix (Starlight prepends base to nav).
  expect(readPage('')).toContain(`href="${BASE}/`);
});

// Journey 2
test('sidebar has both groups with the Getting Started pages in order', () => {
  const html = readPage('installation');
  expect(html).toContain('Getting Started');
  expect(html).toContain('Reference');
  // All seven sidebar hrefs resolve to a built page.
  const links = [
    '', 'installation', 'authentication', 'configuration',
    'nebariapp-crd-reference', 'auth-flow', 'release-readiness',
  ];
  for (const slug of links) {
    const href = slug === '' ? `${BASE}/` : `${BASE}/${slug}/`;
    expect(html).toContain(`href="${href}"`);
    expect(existsSync(pagePath(slug))).toBe(true);
  }
  // Order within Getting Started: Installation -> Authentication -> Configuration.
  const idxInstall = html.indexOf(`href="${BASE}/installation/"`);
  const idxAuth = html.indexOf(`href="${BASE}/authentication/"`);
  const idxConfig = html.indexOf(`href="${BASE}/configuration/"`);
  expect(idxAuth).toBeGreaterThan(idxInstall);
  expect(idxConfig).toBeGreaterThan(idxAuth);
});

// Journey 3
test('every internal link is base-prefixed and resolves to a file at dist root', () => {
  const hrefRe = /(?:href|src)="([^"]+)"/g;
  for (const file of allHtmlFiles()) {
    const html = readFileSync(file, 'utf8');
    let m: RegExpExecArray | null;
    while ((m = hrefRe.exec(html)) !== null) {
      const url = m[1];
      if (!url.startsWith('/') || url.startsWith('//')) continue; // external / protocol-relative
      // Internal links must carry the production base prefix.
      expect(url === BASE || url.startsWith(`${BASE}/`)).toBe(true);
      // Strip the base prefix (the Worker does this in prod), then resolve at dist root.
      const afterBase = url.slice(BASE.length);
      const clean = afterBase.split('#')[0].split('?')[0].replace(/\/$/, '');
      const rel = clean.replace(/^\//, '');
      const asIndex = rel === '' ? join(DIST, 'index.html') : join(DIST, rel, 'index.html');
      const asFile = join(DIST, rel);
      expect(existsSync(asIndex) || existsSync(asFile)).toBe(true);
    }
  }
});

// Journey 4
test('Nebari branding: magenta accent, Space Grotesk headings, footer, portal logo link', () => {
  const home = readPage('');
  expect(home).toMatch(/<a[^>]*href="https:\/\/packs\.nebari\.dev\/"[^>]*class="nbr-site-title\b/);
  expect(home).toContain('data-nebari-footer');
  const css = allCss();
  expect(css).toMatch(/--sl-color-accent:\s*var\(--nbr-brand\)/);
  expect(css).toMatch(/--nbr-font-heading:\s*["']?Space Grotesk/);
});

// Journey 5
test('Pagefind search bundle is emitted and the unique term is indexable', () => {
  const pf = join(DIST, 'pagefind');
  expect(existsSync(join(pf, 'pagefind.js'))).toBe(true);
  expect(existsSync(join(pf, 'pagefind-entry.json'))).toBe(true);
  expect(readPage('nebariapp-crd-reference')).toContain('NebariApp');
});

// Journey 6
test('edit links point to the correct GitHub source file', () => {
  const html = readPage('auth-flow');
  expect(html).toContain(
    'https://github.com/nebari-dev/harbor-pack/edit/main/docs/src/content/docs/auth-flow.md',
  );
});
