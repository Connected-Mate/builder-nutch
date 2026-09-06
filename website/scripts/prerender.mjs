import { readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'vite';
import { createElement } from 'react';
import { renderToString } from 'react-dom/server';

const server = await createServer({
  server: { middlewareMode: true },
  appType: 'custom',
  mode: 'production',
});
try {
  const { default: Home } = await server.ssrLoadModule('/app/page.tsx');
  const html = await readFile('dist/index.html', 'utf8');
  await writeFile(
    'dist/index.html',
    html.replace(
      '<div id="root"></div>',
      `<div id="root">${renderToString(createElement(Home))}</div>`,
    ),
  );
  console.log('Pre-rendered the full landing page for static hosting.');
} finally {
  await server.close();
}
