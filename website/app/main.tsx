import { StrictMode } from 'react';
import { createRoot, hydrateRoot } from 'react-dom/client';
import Home from './page';
import './globals.css';

const root = document.getElementById('root')!;
const app = (
  <StrictMode>
    <Home />
  </StrictMode>
);
if (root.hasChildNodes()) {
  hydrateRoot(root, app);
} else {
  createRoot(root).render(app);
}
