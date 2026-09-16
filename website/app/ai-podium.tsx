import { useEffect, useRef, useState, type CSSProperties } from 'react';
import { ArrowDown, ArrowLeft, ArrowUpRight, Check, Download } from 'lucide-react';
import { podiumTiers } from './podium-tiers';

const asset = (path: string) => `${import.meta.env.BASE_URL}${path}`;
const download = 'https://github.com/Connected-Mate/builder-nutch/releases/latest';

export default function AIPodium() {
  const [selected, setSelected] = useState(6);
  const pickerRef = useRef<HTMLFieldSetElement>(null);
  const tier = podiumTiers[selected];
  const next = podiumTiers[selected + 1];
  const tierStyle = { '--tier-surface': tier.color, '--tier-ink': tier.ink } as CSSProperties;

  useEffect(() => {
    const picker = pickerRef.current;
    const choice = picker?.querySelector<HTMLButtonElement>('[aria-pressed="true"]');
    if (!picker || !choice) return;
    const rail = picker.getBoundingClientRect(), item = choice.getBoundingClientRect();
    if (item.left < rail.left || item.right > rail.right) {
      // Scroll the level strip only; never move the page away from the artwork.
      picker.scrollLeft += item.left - rail.left - (rail.width - item.width) / 2;
    }
  }, [selected]);

  return (
    <div className="ai-podium-page">
      <a href="#main" className="skip-link">Skip to content</a>
      <header className="site-header shell">
        <a className="podium-wordmark" href={asset('ai-podium/')} aria-label="AI Podium home">
          AI Podium<span>by Builder Nutch</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#history">Your history</a>
          <a href="#levels">Your score</a>
          <a href="#sharing">How to share</a>
          <a href={download} className="button button-small">Get the Mac app <ArrowUpRight size={15} /></a>
        </nav>
      </header>
      <main id="main">
        <section className="podium-hero shell" aria-labelledby="podium-heading">
          <a className="quiet-link podium-back" href={asset('')}><ArrowLeft size={14} /> Builder Nutch</a>
          <div className="podium-heading-row">
            <div>
              <p className="eyebrow">AI PODIUM · BUILT ON ACTUAL USAGE</p>
              <h1 id="podium-heading">Less AI talk.<br />Show your work.</h1>
            </div>
            <div className="podium-hero-copy">
              <p>You build with AI. Let your activity speak.</p>
              <p>Download Builder Nutch, recover the history on your Mac, and share your AI Podium. Real token totals, the tools you use, and a clear view of your day.</p>
              <div className="podium-hero-actions">
                <a className="button" href={download}><Download size={18} /> Get my AI Podium</a>
                <a className="quiet-link" href="#tier-preview">See an example <ArrowDown size={16} /></a>
              </div>
              <span className="podium-hero-note">Free &amp; open source · For Mac</span>
            </div>
          </div>
        </section>
        <section className="podium-history shell" id="history" aria-labelledby="history-title">
          <div>
            <p className="eyebrow">YOUR HISTORY COMES WITH YOU</p>
            <h2 id="history-title">Already building?<br />You don’t start at zero.</h2>
          </div>
          <div className="podium-history-copy">
            <p>Builder Nutch reads the Claude Code and Codex session records already on your Mac, including archived Codex sessions. Work recorded before you installed the app can count toward your score.</p>
            <p>Close the app and keep working. It catches up from the records still available when you reopen it. Once captured, your token history is saved separately from the original sessions.</p>
            <p className="podium-history-limit">Deleted records that were never captured cannot be recovered. Missing and partial readings stay visible.</p>
            <a className="quiet-link" href="https://github.com/Connected-Mate/builder-nutch/tree/main/Sources/Insights">See how the counting works <ArrowUpRight size={16} /></a>
          </div>
        </section>
        <section className="podium-levels shell" id="levels" aria-labelledby="levels-title">
          <div className="podium-section-heading">
            <h2 id="levels-title">Your usage. Your score.</h2>
            <p>Nine levels, from White to Black. Based on saved tokens.</p>
          </div>
          <fieldset ref={pickerRef} className="tier-picker" aria-label="Explore token levels">
            {podiumTiers.map((item, index) => (
              <button key={item.id} type="button" className="tier-choice" data-tier={item.id}
                style={{ '--tier-surface': item.color, '--tier-ink': item.ink } as CSSProperties}
                aria-pressed={selected === index} aria-controls="tier-preview"
                onClick={() => setSelected(index)}>
                <span className="tier-choice-top">{String(item.level).padStart(2, '0')}{selected === index && <Check size={14} />}</span>
                <strong>{item.name}</strong><span>{item.threshold} tokens</span>
              </button>
            ))}
          </fieldset>
          <div className="tier-preview-heading" id="tier-preview" aria-live="polite" aria-atomic="true">
            <div className="tier-active" data-tier={tier.id} style={tierStyle}><span>{String(tier.level).padStart(2, '0')}</span>{tier.name}</div>
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
        <section className="podium-gengen shell" aria-labelledby="gengen-title">
          <figure className="gengen-seal" aria-label="GenGen stamp example">
            <span>AI PODIUM</span><strong>GenGen</strong><span>RECORDED ACTIVITY</span>
          </figure>
          <div>
            <p className="eyebrow">THE NEXT STAMP</p>
            <h2 id="gengen-title">Keep building. Earn GenGen.</h2>
            <p>Go beyond Graphite to Obsidian, at 100B saved tokens. Or keep Graphite for two calendar months from its recorded unlock date. Either path unlocks GenGen.</p>
            <p className="gengen-detail">Your saved history determines the stamp. If the Graphite date is unknown, we don’t invent one. Changing the period or project you share does not reset your progress.</p>
          </div>
        </section>
        <section className="podium-sharing shell" id="sharing" aria-labelledby="sharing-title">
          <div>
            <p className="eyebrow">DOWNLOAD. RECOVER. SHARE.</p>
            <h2 id="sharing-title">Make your usage<br />part of the story.</h2>
            <p>Talking about AI is easy. Sharing how you actually use it makes the conversation concrete. Put your score next to what you built.</p>
          </div>
          <ol className="steps">
            <li><span className="step-number">01</span><div><h3>Download the app.</h3><p>Install Builder Nutch on your Mac. Open Usage to read the available Claude Code and Codex history.</p></div></li>
            <li><span className="step-number">02</span><div><h3>Recover your score.</h3><p>Your saved tokens determine your level. Open Share, then choose today, this week, this month or one project.</p></div></li>
            <li><span className="step-number">03</span><div><h3>Be transparent.</h3><p>Copy or save your image and share it on X or LinkedIn alongside your work. You choose when to post and what to say.</p></div></li>
          </ol>
        </section>
        <section className="podium-faq shell" aria-label="About AI Podium levels">
          <details><summary>Does a high score prove expertise?</summary><p>Your score measures recorded token consumption. It does not certify skill, productivity or the quality of what you build. Share it with the work itself to give the numbers context. There is no public leaderboard or requirement to publish.</p></details>
          <details><summary>Did I need Builder Nutch running from the start?</summary><p>No. Existing Claude Code and Codex records can be read when you first open the app or return later. The records must still be on this Mac. Captured token history stays saved locally after the original sessions are cleaned up.</p></details>
          <details><summary>Do levels reset each day?</summary><p>No. Levels use the token history saved on your Mac. Changing the chart period or sharing a project does not reset your level. Saved readings remain after session files are cleaned up.</p></details>
          <details><summary>Which tokens count?</summary><p>Recorded input, cache and output from Claude Code and Codex. Reasoning is already part of output and is not counted twice. Missing readings are never invented; partial totals stay marked.</p></details>
          <details><summary>What appears in the image?</summary><p>Token totals, dates, your level and today’s AI ranking. Accounts and conversations stay private. A project name appears only when you choose a project and personal details are visible. Posting is always your choice.</p></details>
        </section>
        <section className="podium-download shell">
          <h2>Build something.<br />Show the AI behind it.</h2>
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
