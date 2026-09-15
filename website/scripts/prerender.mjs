import { mkdir, readFile, writeFile } from 'node:fs/promises';
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
  const { default: AIPodium } = await server.ssrLoadModule('/app/ai-podium.tsx');
  const html = await readFile('dist/index.html', 'utf8');
  await writeFile(
    'dist/index.html',
    html.replace(
      '<div id="root"></div>',
      `<div id="root">${renderToString(createElement(Home))}</div>`,
    ),
  );
  const podiumURL = 'https://connected-mate.github.io/builder-nutch/ai-podium/';
  const podiumHTML = html
    .replace(/<title>[^<]*<\/title>/, '<title>AI Podium — Your AI. Your next level.</title>')
    .replace(/content="Builder Nutch — Build more\. Share your AI Podium\."/, 'content="AI Podium — Your AI. Your next level."')
    .replace(/content="Manage your AI subscriptions[^\"]*"/, 'content="Your daily AI ranking and lifetime token level, from White to Black. Explore Gold, Platinum and more, then share your AI Podium from Builder Nutch for Mac."')
    .replace(/content="Your token activity and today’s most-used AI[^\"]*"/, 'content="From White to Black, your level grows with your saved tokens. Share your day, week, month or project with AI Podium."')
    .replaceAll('https://connected-mate.github.io/builder-nutch/"', `${podiumURL}"`)
    .replace('<div id="root"></div>', `<div id="root">${renderToString(createElement(AIPodium))}</div>`);
  await mkdir('dist/ai-podium', { recursive: true });
  await writeFile('dist/ai-podium/index.html', podiumHTML);
  console.log('Pre-rendered the home and AI Podium pages for static hosting.');
} finally {
  await server.close();
}
