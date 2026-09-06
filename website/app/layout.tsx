import type { Metadata } from 'next';
import { Barlow_Condensed, Manrope } from 'next/font/google';
import './globals.css';

const display = Barlow_Condensed({ variable: '--font-display', subsets: ['latin'], weight: ['600', '700'] });
const body = Manrope({ variable: '--font-body', subsets: ['latin'] });
export const metadata: Metadata = {
  metadataBase: new URL('https://codenotch-accounts.alexandre-cormeraie.chatgpt.site'),
  title: 'Builder Nutch — Big ideas. Lean R&D. Keep building.',
  description: 'Put your AI subscriptions to work. Manage Claude Code and Codex accounts on your Mac, see remaining usage, and automatically choose an available account for your next session. Built for ambitious experiments and real products.',
  icons: { icon: '/app-icon.png' },
};
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body className={`${display.variable} ${body.variable}`}>{children}</body></html>;
}
