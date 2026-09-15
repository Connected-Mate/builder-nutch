import { useState, type CSSProperties } from 'react';
import { ArrowDown, ArrowLeft, ArrowUpRight, Check, Download } from 'lucide-react';
import { podiumTiers } from './podium-tiers';

const asset = (path: string) => `${import.meta.env.BASE_URL}${path}`;
const download = 'https://github.com/Connected-Mate/builder-nutch/releases/latest';

export default function AIPodium() {
  const [selected, setSelected] = useState(6);
  const tier = podiumTiers[selected];
  const next = podiumTiers[selected + 1];
  const tierStyle = { '--tier-surface': tier.color, '--tier-ink': tier.ink } as CSSProperties;

  return (
    <div className="ai-podium-page">
      <a href="#main" className="skip-link">Skip to content</a>
      <header className="site-header shell">
        <a className="podium-wordmark" href={asset('ai-podium/')} aria-label="AI Podium home">
          AI Podium<span>by Builder Nutch</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#levels">The levels</a>
          <a href="#sharing">How to share</a>
          <a href={download} className="button button-small">Get the Mac app <ArrowUpRight size={15} /></a>
        </nav>
      </header>
      <main id="main">
        <section className="podium-hero shell" aria-labelledby="podium-heading">
          <a className="quiet-link podium-back" href={asset('')}><ArrowLeft size={14} /> Builder Nutch</a>
          <div className="podium-heading-row">
            <div>
              <p className="eyebrow">TODAY’S AI PODIUM</p>
              <h1 id="podium-heading">Your AI.<br />Your next level.</h1>
            </div>
            <div className="podium-hero-copy">
              <p>Your token activity, your most-used AI, your place on the scale.</p>
              <p>From White to Black, your level grows with your saved history. Turn your day, week, month or project into an image you can share.</p>
              <a className="quiet-link" href="#tier-preview">See today’s podium <ArrowDown size={16} /></a>
            </div>
          </div>
        </section>
        <section className="podium-levels shell" id="levels" aria-labelledby="levels-title">
          <div className="podium-section-heading">
            <h2 id="levels-title">From White to Black.</h2>
            <p>Nine levels. Based on all your saved tokens.</p>
          </div>
          <fieldset className="tier-picker" aria-label="Explore token levels">
            {podiumTiers.map((item, index) => (
              <button key={item.id} type="button" className="tier-choice"
                style={{ '--tier-surface': item.color, '--tier-ink': item.ink } as CSSProperties}
                aria-pressed={selected === index} aria-controls="tier-preview"
                onClick={() => setSelected(index)}>
                <span className="tier-choice-top">{String(item.level).padStart(2, '0')}{selected === index && <Check size={14} />}</span>
                <strong>{item.name}</strong><span>{item.threshold} tokens</span>
              </button>
            ))}
          </fieldset>
          <div className="tier-preview-heading" id="tier-preview" aria-live="polite" aria-atomic="true">
            <div className="tier-active" style={tierStyle}><span>{String(tier.level).padStart(2, '0')}</span>{tier.name}</div>
            <p>{tier.level === 0 ? 'Unlocked with your first recorded token.' : `Reached at ${tier.threshold} lifetime tokens.`}
              {' '}{next ? `Next: ${next.name} at ${next.threshold}.` : 'The final level.'}</p>
            <span className="podium-example-label">Example preview</span>
          </div>
          <figure className="podium-showcase">
            <div className="podium-showcase-kicker" aria-hidden="true">
              <span>AI PODIUM / {String(tier.level).padStart(2, '0')}</span>
              <span>{tier.name.toUpperCase()} FINISH</span>
            </div>
            <a href={asset(`screenshots/podium-level-${tier.level}.png`)} target="_blank" rel="noreferrer" aria-label="Open full-size AI Podium example">
              <img src={asset(`screenshots/podium-level-${tier.level}.png`)} width={2400} height={1260}
                alt={`${tier.name} AI Podium example: recorded token totals and the most-used AI, ranked by daily use.`} fetchPriority="high" />
            </a>
            <figcaption>Example data, exported from Builder Nutch. Your level follows your saved history, independently of the period or project you share.</figcaption>
          </figure>
        </section>
        <section className="podium-sharing shell" id="sharing" aria-labelledby="sharing-title">
          <div>
            <p className="eyebrow">BUILD. CAPTURE. SHARE.</p>
            <h2 id="sharing-title">Your day,<br />ready to post.</h2>
            <p>Keep a visual record of your AI activity. Share it on X, LinkedIn or wherever you build in public.</p>
          </div>
          <ol className="steps">
            <li><span className="step-number">01</span><div><h3>Choose your moment.</h3><p>Open Share in Usage. Pick today, this week, this month or a project.</p></div></li>
            <li><span className="step-number">02</span><div><h3>Your podium takes shape.</h3><p>Your leading AI sets the lighting. Your lifetime level sets the token card’s finish, from light to dark.</p></div></li>
            <li><span className="step-number">03</span><div><h3>Make it yours to share.</h3><p>Copy or save the image in full resolution, then attach it to your post. An optional 17:30 reminder brings you back to today’s preview.</p></div></li>
          </ol>
        </section>
        <section className="podium-faq shell" aria-label="About AI Podium levels">
          <details><summary>Do levels reset each day?</summary><p>No. Levels use the token history saved on your Mac. Changing the chart period or sharing a project does not reset your level. Saved readings remain after session files are cleaned up.</p></details>
          <details><summary>Which tokens count?</summary><p>Recorded input, cache and output from Claude Code and Codex. Reasoning is already part of output and is not counted twice. Missing readings are never invented; partial totals stay marked.</p></details>
          <details><summary>What appears in the image?</summary><p>Token totals, dates, your level and today’s AI ranking. Accounts and conversations stay private. A project name appears only when you choose a project and personal details are visible. Posting is always your choice.</p></details>
        </section>
        <section className="podium-download shell">
          <h2>Meet your AI Podium.</h2>
          <a className="button" href={download}><Download size={18} /> Get Builder Nutch for Mac</a>
          <p>macOS 26+ · Apple Silicon &amp; Intel · Free &amp; open source</p>
        </section>
      </main>
      <footer className="shell">
        <a className="podium-wordmark" href={asset('ai-podium/')}>AI Podium<span>by Builder Nutch</span></a>
        <div className="footer-links"><a href={asset('')}>The Mac app <ArrowUpRight size={14} /></a><a href="https://github.com/Connected-Mate/builder-nutch">GitHub <ArrowUpRight size={14} /></a></div>
        <p className="legal">© 2026 Connected Mate · Built on Codenotch by Vinz. All provider names and logos belong to their respective owners.</p>
      </footer>
    </div>
  );
}
