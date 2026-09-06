'use client';

import { useState } from 'react';
import Image from 'next/image';
import Link from 'next/link';
import { ArrowUpRight, ArrowRight, Check, GitFork, Download, ShieldCheck, Command, Plus } from 'lucide-react';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { Button } from '@/components/ui/button';

const repository = 'https://github.com/Connected-Mate/codenotch-accounts';
const examples = [
  { name: 'Personal', plan: 'Daily work', remaining: 7, reset: 'Resets in 42 min' },
  { name: 'Client projects', plan: 'Production builds', remaining: 81, reset: 'Resets in 3 h 18 min' },
  { name: 'Side projects', plan: 'The next big thing', remaining: 64, reset: 'Resets in 2 h 6 min' },
];

function AccountPreview() {
  const [chosen, setChosen] = useState<Record<string, number>>({ claude: 0, codex: 0 });
  const [provider, setProvider] = useState('claude');
  const selected = chosen[provider];
  return <div className="product-preview">
    <div className="window-top"><span className="window-dots" aria-hidden="true"><i/><i/><i/></span><span>Codenotch Accounts</span><Command size={14}/></div>
    <div className="preview-heading"><div><span className="overline">YOUR NEXT SESSION</span><h2>Choose your account.</h2></div><span className="sample-label">Interactive preview</span></div>
    <Tabs value={provider} onValueChange={(value) => setProvider(String(value))}>
      <TabsList className="provider-tabs" aria-label="Preview provider"><TabsTrigger value="claude">Claude Code</TabsTrigger><TabsTrigger value="codex">Codex</TabsTrigger></TabsList>
      {['claude', 'codex'].map(vendor => <TabsContent key={vendor} value={vendor}>
        <div className="preview-rows">
          {examples.map((account, i) => <div className={`preview-row ${selected === i ? 'selected' : ''}`} key={account.name}>
            <div className={`quota-ring ${account.remaining < 10 ? 'low' : ''}`} style={{ '--remaining': `${account.remaining}%` } as React.CSSProperties} aria-label={`${account.remaining}% remaining`}><span>{account.remaining}<small>%</small></span></div>
            <div className="account-label"><strong>{account.name}</strong><span>{account.reset}</span></div>
            <Button variant="ghost" className="select-account" onClick={() => setChosen(prev => ({ ...prev, [provider]: i }))} aria-label={`Select ${account.name} for ${provider === 'claude' ? 'Claude Code' : 'Codex'}`} aria-pressed={selected === i}>{selected === i ? <><Check size={14}/>Active</> : <>Use <ArrowRight size={14}/></>}</Button>
          </div>)}
        </div>
      </TabsContent>)}
    </Tabs>
    <div className="preview-footer" aria-live="polite"><span className="status-dot"/>Next {provider === 'claude' ? 'Claude Code' : 'Codex'} session: <strong>{examples[selected].name}</strong></div>
    <p className="sample-note">Sample accounts and usage. Try switching between them.</p>
  </div>;
}

export default function Home() {
  return <>
    <a href="#main" className="skip-link">Skip to content</a>
    <div className="site-shell">
      <header className="site-header"><Link className="wordmark" href="/" aria-label="Codenotch Accounts home"><Image src="/app-icon.png" width={34} height={34} alt="" unoptimized/><span>codenotch<span className="wordmark-sub">ACCOUNTS</span></span></Link><nav aria-label="Main navigation"><a href="#how-it-works">How it works</a><a href={repository} target="_blank" rel="noreferrer">GitHub <ArrowUpRight size={14}/></a><a href="#get-the-app" className="header-cta">Get the app <ArrowRight size={14}/></a></nav></header>
      <main id="main">
        <section className="hero" aria-labelledby="hero-title">
          <div className="hero-copy"><p className="eyebrow"><span className="status-dot"/> CLAUDE CODE + CODEX · ON YOUR MAC</p><h1 id="hero-title">More accounts.<br/>Less downtime.<br/><span>Keep shipping.</span></h1><p className="hero-description">Your AI subscriptions belong in one place. Connect your accounts, see what’s left, and choose the right one for your next session.</p><div className="hero-actions"><a className="primary-link" href="#get-the-app">Get Codenotch Accounts <ArrowRight size={18}/></a><a className="text-link" href={repository}><GitFork size={18}/> Explore the source</a></div><p className="compatibility">macOS 26+ <span>·</span> Open source <span>·</span> Your accounts stay on your Mac</p></div>
          <div className="hero-product"><AccountPreview/><span className="preview-caption"><span>01 / ONE PLACE FOR EVERY ACCOUNT</span><span>Made from Codenotch <ArrowUpRight size={12}/></span></span></div>
        </section>
        <div className="manifesto"><span className="overline">FOR THE WORK THAT MATTERS</span><p>Built for people who <em>ship.</em><br/>From the first commit to production.</p><span className="manifesto-note">Fewer account switches to think about.<br/>More attention for the thing you’re building.</span></div>
        <section className="workflow" id="how-it-works" aria-labelledby="workflow-title"><div className="section-heading"><p className="overline">LESS FRICTION. SAME TOOLS.</p><h2 id="workflow-title">Three steps.<br/>Back to building.</h2></div><ol className="steps"><li><span className="step-number">01</span><div><h3>Connect your accounts.</h3><p>Add a label. Sign in through the official Claude Code or Codex browser flow. Repeat for every account you own.</p></div><Plus size={21}/></li><li><span className="step-number">02</span><div><h3>Know what’s available.</h3><p>Keep selected accounts in Codenotch’s familiar screen-edge rings. Open the manager for usage windows, resets and all your profiles.</p></div><Command size={21}/></li><li><span className="step-number">03</span><div><h3>Choose once. Launch.</h3><p>Pick an account and project, then start your next session. Optional automatic selection chooses an available account from fresh readings.</p></div><ArrowUpRight size={21}/></li></ol></section>
        <section className="ownership" aria-labelledby="ownership-title"><div className="ownership-title"><ShieldCheck size={25}/><h2 id="ownership-title">Your accounts.<br/>Your Mac. Your control.</h2></div><div className="ownership-copy"><p>No new password to remember. No token to paste. The official tools handle authentication and keep their credentials locally.</p><p>A switch applies to new sessions launched from the manager. Running work keeps its original account. Provider limits still apply.</p><a href={`${repository}#how-account-isolation-works`} className="text-link">See how it works under the hood <ArrowUpRight size={16}/></a></div></section>
        <section className="faq" aria-labelledby="faq-title"><h2 id="faq-title">A few honest answers.</h2><div className="faq-list"><details><summary>Can I connect six accounts for each provider?</summary><p>Yes. Accounts are separate local profiles, with no six-account cap. You sign in to each through the provider’s official tool.</p></details><details><summary>Does this give me unlimited AI usage?</summary><p>No. Each subscription keeps its own limits and terms. Codenotch Accounts helps you see your accounts and choose one for your next session. It does not increase quotas.</p></details><details><summary>Will it switch a session that’s already running?</summary><p>No. Running sessions keep their original account and are never stopped by a switch. Start your next Claude Code or Codex terminal session from the manager to use your selected profile.</p></details><details><summary>When do usage readings appear?</summary><p>Codex reads usage from its official app server. Claude Code supplies usage after you start using a managed session. Unavailable or old readings are shown as unknown or stale, never as an invented allowance.</p></details><details><summary>Does it replace Claude.ai or ChatGPT?</summary><p>No. This manages accounts for the Claude Code and Codex tools on your Mac. Browser chats and separate desktop conversations keep their own logins.</p></details></div></section>
        <section className="get-app" id="get-the-app"><div><p className="overline">AN OPEN-SOURCE COMMUNITY FORK</p><h2>Less juggling.<br/>More shipping.</h2><p>Built on <a href="https://github.com/vinzdg/codenotch">Codenotch by Vinz</a>.<br/>Extended for the way you work.</p></div><div className="download-block"><a className="primary-link" href={`${repository}/releases/latest`}><Download size={18}/> Download for Mac</a><span>macOS 26+ · Apple Silicon & Intel</span><a className="text-link" href={`${repository}#build-and-install`}>Build from source <ArrowUpRight size={16}/></a></div></section>
      </main>
      <footer><span>© 2026 Connected Mate · MIT license</span><span>Independent project. Not affiliated with Anthropic or OpenAI.</span><a href={repository}>Source <ArrowUpRight size={13}/></a></footer>
    </div>
  </>;
}
