'use client';

import { useState } from 'react';
import Image from 'next/image';
import Link from 'next/link';
import { ArrowUpRight, ArrowRight, Check, GitFork, Download, ShieldCheck, Command, Plus } from 'lucide-react';
import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { Button } from '@/components/ui/button';

const repository = 'https://github.com/Connected-Mate/builder-nutch';
const examples = [
  { name: 'Personal', plan: 'Daily work', remaining: 0, reset: 'Limit reached · resets in 42 min' },
  { name: 'Client projects', plan: 'Production builds', remaining: 81, reset: 'Resets in 3 h 18 min' },
  { name: 'Side projects', plan: 'The next big thing', remaining: 64, reset: 'Resets in 2 h 6 min' },
];

function AccountPreview() {
  const [chosen, setChosen] = useState<Record<string, number>>({ claude: 0, codex: 0 });
  const [provider, setProvider] = useState('claude');
  const selected = chosen[provider];
  return <div className="product-preview">
    <div className="window-top"><span className="window-dots" aria-hidden="true"><i/><i/><i/></span><span>Builder Nutch</span><Command size={14}/></div>
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
    <div className="preview-auto"><Button variant="ghost" className="auto-pick" onClick={() => setChosen(prev => ({ ...prev, [provider]: examples.reduce((best, account, i) => account.remaining > examples[best].remaining ? i : best, 0) }))}><ArrowRight size={15}/> Auto-pick for next session</Button></div>
    <div className="preview-footer" aria-live="polite"><span className="status-dot"/>Next {provider === 'claude' ? 'Claude Code' : 'Codex'} session: <strong>{examples[selected].name}</strong></div>
    <p className="sample-note">Sample data. Try automatic selection when an account hits its limit.</p>
  </div>;
}

export default function Home() {
  return <>
    <a href="#main" className="skip-link">Skip to content</a>
    <div className="site-shell">
      <header className="site-header"><Link className="wordmark" href="/" aria-label="Builder Nutch home"><Image src="/app-icon.png" width={34} height={34} alt="" unoptimized/><span>builder<span className="wordmark-sub">NUTCH</span></span></Link><nav aria-label="Main navigation"><a href="#how-it-works">How it works</a><a href={repository} target="_blank" rel="noreferrer">GitHub <ArrowUpRight size={14}/></a><a href="#get-the-app" className="header-cta">Get the app <ArrowRight size={14}/></a></nav></header>
      <main id="main">
        <section className="hero" aria-labelledby="hero-title">
          <div className="hero-copy"><p className="eyebrow"><span className="status-dot"/> FOR BUILDERS WITH MULTIPLE AI SUBSCRIPTIONS</p><h1 id="hero-title">Big ideas.<br/>Lean R&amp;D.<br/><span>Keep building.</span></h1><p className="hero-description">Get more experiments, prototypes and production work out of the AI subscriptions you already pay for. Bring your Claude Code and Codex accounts together. Let available quota guide your next session.</p><div className="hero-actions"><a className="primary-link" href="#get-the-app">Get Builder Nutch <ArrowRight size={18}/></a><a className="text-link" href={repository}><GitFork size={18}/> Explore the source</a></div><p className="compatibility">macOS 26+ <span>·</span> Open source <span>·</span> Your accounts stay on your Mac</p></div>
          <div className="hero-product"><AccountPreview/><span className="preview-caption"><span>01 / YOUR SUBSCRIPTIONS, PUT TO WORK</span><span>Made from Codenotch <ArrowUpRight size={12}/></span></span></div>
        </section>
        <div className="manifesto"><span className="overline">TODAY’S AI. TOMORROW’S BREAKTHROUGHS.</span><p>Serious builders.<br/>Subscription-sized <em>R&amp;D.</em></p><span className="manifesto-note">Test the wild idea. Ship the useful one.<br/>Make the most of what you already pay for.</span></div>
        <section className="workflow" id="how-it-works" aria-labelledby="workflow-title"><div className="section-heading"><p className="overline">LESS ADMIN. MORE EXPERIMENTS.</p><h2 id="workflow-title">More time<br/>on the real work.</h2></div><ol className="steps"><li><span className="step-number">01</span><div><h3>Connect your accounts.</h3><p>Add a label. Sign in through the official Claude Code or Codex browser flow. Repeat for every account you own.</p></div><Plus size={21}/></li><li><span className="step-number">02</span><div><h3>Know what’s available.</h3><p>See remaining usage and resets at a glance in your Mac’s notch. Keep every profile in one place, ready for the next experiment or production build.</p></div><Command size={21}/></li><li><span className="step-number">03</span><div><h3>One limit reached? Launch with room.</h3><p>Enable automatic selection. When you launch, Builder Nutch picks a connected account with fresh, verified quota and skips accounts at their limit. Existing sessions keep their account.</p></div><ArrowUpRight size={21}/></li></ol></section>
        <section className="ownership" aria-labelledby="ownership-title"><div className="ownership-title"><ShieldCheck size={25}/><h2 id="ownership-title">Build ambitiously.<br/>Stay in control.</h2></div><div className="ownership-copy"><p>Your subscriptions should fuel your ideas. Connect each account through the official tool’s browser login. Your credentials stay on your Mac, managed by Claude Code and Codex.</p><p>Choose a profile yourself or let verified quota guide the next launch. Automatic selection works across accounts of the same provider. Each subscription keeps its own limits and terms.</p><a href={`${repository}#how-account-isolation-works`} className="text-link">See how it works under the hood <ArrowUpRight size={16}/></a></div></section>
        <section className="faq" aria-labelledby="faq-title"><h2 id="faq-title">Before your next big idea.</h2><div className="faq-list"><details><summary>Can I connect six accounts for each provider?</summary><p>Yes. Accounts are separate local profiles, with no six-account cap. You sign in to each through the provider’s official tool.</p></details><details><summary>Does this give me unlimited AI usage?</summary><p>No. Each subscription keeps its own limits and terms. Builder Nutch helps you see your accounts and choose one for your next session. It does not increase quotas.</p></details><details><summary>Does it switch automatically when I hit a limit?</summary><p>Automatic selection happens when you launch your next session from Builder Nutch. It skips accounts with a reached limit, stale usage or no connection, and chooses an eligible account with the most available quota. It does not move a running conversation to another account. If no account qualifies, it asks you to connect or refresh.</p></details><details><summary>When do usage readings appear?</summary><p>Codex reads usage from its official app server. Claude Code supplies usage after you start using a managed session. Unavailable or old readings are shown as unknown or stale, never as an invented allowance.</p></details><details><summary>Does it replace Claude.ai or ChatGPT?</summary><p>No. This manages accounts for the Claude Code and Codex tools on your Mac. Browser chats and separate desktop conversations keep their own logins.</p></details></div></section>
        <section className="get-app" id="get-the-app"><div><p className="overline">MAKE YOUR NEXT EXPERIMENT COUNT</p><h2>Use the AI.<br/>Build the thing.</h2><p>Built on <a href="https://github.com/vinzdg/codenotch">Codenotch by Vinz</a>.<br/>Built for people who put AI to work.</p></div><div className="download-block"><a className="primary-link" href={`${repository}/releases/latest`}><Download size={18}/> Download for Mac</a><span>macOS 26+ · Apple Silicon & Intel</span><a className="text-link" href={`${repository}#build-and-install`}>Build from source <ArrowUpRight size={16}/></a></div></section>
      </main>
      <footer><span>© 2026 Connected Mate · MIT license</span><span>Independent project. Not affiliated with Anthropic or OpenAI.</span><a href={repository}>Source <ArrowUpRight size={13}/></a></footer>
    </div>
  </>;
}
