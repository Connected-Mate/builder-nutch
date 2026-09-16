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
    .replace(/<title>[^<]*<\/title>/, '<title>AI Podium — Less AI talk. Show your work.</title>')
    .replace(/content="Builder Nutch — Build more\. Share your AI Podium\."/, 'content="AI Podium — Less AI talk. Show your work."')
    .replace(/content="Manage your AI subscriptions[^\"]*"/, 'content="Download Builder Nutch, recover your local Claude Code and Codex history, and share your AI Podium score alongside what you build. Free and open source for Mac."')
    .replace(/content="Your token activity and today’s most-used AI[^\"]*"/, 'content="Real token history, your most-used AI and a score you can share. Recover your local activity and make your AI usage transparent with AI Podium."')
    .replaceAll('https://connected-mate.github.io/builder-nutch/"', `${podiumURL}"`)
    .replace('<div id="root"></div>', `<div id="root">${renderToString(createElement(AIPodium))}</div>`);
  await mkdir('dist/ai-podium', { recursive: true });
  await writeFile('dist/ai-podium/index.html', podiumHTML);
  console.log('Pre-rendered the home and AI Podium pages for static hosting.');
} finally {
  await server.close();
}
