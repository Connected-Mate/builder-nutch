import { StrictMode } from 'react';
import { createRoot, hydrateRoot } from 'react-dom/client';
import Home from './page';
import AIPodium from './ai-podium';
import GenGen from './gengen';
import './globals.css';
import './ai-podium.css';

const root = document.getElementById('root')!;
const pathname = window.location.pathname.replace(/\/+$/, '').replace(/\/index\.html$/, '');
const isPodium = pathname === `${import.meta.env.BASE_URL}ai-podium`;
const isGenGen = pathname === `${import.meta.env.BASE_URL}gengen`;
const app = (
  <StrictMode>
    {isGenGen ? <GenGen /> : isPodium ? <AIPodium /> : <Home />}
  </StrictMode>
);
if (root.hasChildNodes()) {
  hydrateRoot(root, app);
} else {
  createRoot(root).render(app);
}
