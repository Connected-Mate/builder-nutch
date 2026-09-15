import { StrictMode } from 'react';
import { createRoot, hydrateRoot } from 'react-dom/client';
import Home from './page';
import AIPodium from './ai-podium';
import './globals.css';
import './ai-podium.css';

const root = document.getElementById('root')!;
const isPodium = window.location.pathname.replace(/\/+$/, '') === `${import.meta.env.BASE_URL}ai-podium`;
const app = (
  <StrictMode>
    {isPodium ? <AIPodium /> : <Home />}
  </StrictMode>
);
if (root.hasChildNodes()) {
  hydrateRoot(root, app);
} else {
  createRoot(root).render(app);
}
