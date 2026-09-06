import type { Metadata } from 'next';
import { Barlow_Condensed, Manrope } from 'next/font/google';
import './globals.css';

const display = Barlow_Condensed({ variable: '--font-display', subsets: ['latin'], weight: ['600', '700'] });
const body = Manrope({ variable: '--font-body', subsets: ['latin'] });
export const metadata: Metadata = {
  metadataBase: new URL('https://codenotch-accounts.tasty-ball-9449.chatgpt.site'),
  title: 'Codenotch Accounts — Built for people who ship',
  description: 'Your Claude Code and Codex accounts, together on your Mac. Connect through official browser login, see usage, and choose the account for your next session.',
  icons: { icon: '/app-icon.png' },
};
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body className={`${display.variable} ${body.variable}`}>{children}</body></html>;
}
