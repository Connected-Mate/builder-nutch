import { ArrowDown, ArrowLeft, ArrowUpRight, Download } from 'lucide-react';
import GenGenSeal from './gengen-seal';
import './gengen.css';

const asset = (path: string) => `${import.meta.env.BASE_URL}${path}`;
const download = 'https://github.com/Connected-Mate/builder-nutch/releases/latest';

export default function GenGen() {
  return (
    <div className="ai-podium-page gengen-page">
      <a href="#main" className="skip-link">Skip to content</a>
      <header className="site-header shell">
        <a className="podium-wordmark" href={asset('gengen/')} aria-label="GenGen home">
          GenGen<span>by AI Podium</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#meaning">The idea</a>
          <a href="#eligibility">Earn the stamp</a>
          <a href={download} className="button button-small">Get the Mac app <ArrowUpRight size={15} /></a>
        </nav>
      </header>
      <main id="main">
        <section className="gengen-hero shell" aria-labelledby="gengen-heading">
          <a className="quiet-link gengen-back" href={asset('ai-podium/')}><ArrowLeft size={14} /> AI Podium</a>
          <div className="gengen-hero-layout">
            <div>
              <p className="eyebrow">GENGEN · GENERATIVE GENERATION</p>
              <h1 id="gengen-heading">A generation<br />that builds.</h1>
            </div>
            <div className="gengen-hero-copy">
              <p>AI moves fast. Get your hands on it.</p>
              <p>GenGen is a lifetime stamp for recorded AI activity. For people experimenting, building and putting work into the world. Show your usage. Then show what you made.</p>
              <a className="quiet-link" href="#label">Meet the label <ArrowDown size={16} /></a>
            </div>
          </div>
        </section>

        <section className="gengen-label-section shell" id="label" aria-label="Illustrative GenGen label">
          <figure className="gengen-label-exhibit">
            <div className="gengen-exhibit-heading"><span>THE GENGEN LABEL</span><span>ILLUSTRATIVE EXAMPLE</span></div>
            <div className="gengen-paper">
              <div className="gengen-paper-heading"><span>AI PODIUM / BUILDER NUTCH</span><span>LIFETIME STAMP</span></div>
              <div className="gengen-paper-title"><strong>GenGen</strong><span>generative generation</span></div>
              <p className="gengen-paper-statement">Hands on.<br />Work shown.</p>
              <div className="gengen-paper-bottom">
                <div className="gengen-paper-record">
                  <span className="gengen-paper-kicker">WHAT THE LABEL RECORDS</span>
                  <p>AI activity, measured from<br />retained local history.</p>
                  <span className="gengen-paper-principle">The score starts the conversation.<br />The work gives it meaning.</span>
                </div>
                <GenGenSeal />
              </div>
            </div>
            <figcaption>Illustrative label, not an issued certificate. Your own GenGen stamp appears in your AI Podium when your saved history meets either eligibility path.</figcaption>
          </figure>
        </section>

        <section className="gengen-editorial shell" id="meaning" aria-labelledby="gengen-meaning-title">
          <div className="gengen-section-intro">
            <p className="eyebrow">THE GENERATIVE GENERATION</p>
            <h2 id="gengen-meaning-title">Less commentary.<br />More contact.</h2>
          </div>
          <div className="gengen-prose">
            <p className="gengen-lead">The models change. The tools change. What you can build changes. Stay close to the work.</p>
            <p>GenGen means <strong>generative generation</strong>: people learning by using AI, trying ideas, finding the limits and making something real. It is a way of working, not an age group or a job title.</p>
            <p>Big claims deserve something concrete. Ask for their score <em>and</em> their work. Share recent projects with dates, decisions and results. Recorded usage shows activity; the work shows what came of it.</p>
            <p className="gengen-context">Tokens measure consumption. They cannot determine competence, productivity or quality. GenGen keeps that distinction clear: an activity label, with the work beside it.</p>
          </div>
        </section>

        <section className="gengen-eligibility shell" id="eligibility" aria-labelledby="gengen-eligibility-title">
          <div className="gengen-section-intro">
            <p className="eyebrow">TWO PATHS. ONE STAMP.</p>
            <h2 id="gengen-eligibility-title">Earn it through<br />your saved history.</h2>
            <p>GenGen is separate from the nine AI Podium levels. Either path unlocks the lifetime stamp.</p>
          </div>
          <div className="gengen-paths">
            <div className="gengen-path">
              <span className="gengen-path-number" aria-hidden="true">01</span>
              <div><h3>Reach Obsidian.</h3><p>Record <strong>100 billion lifetime tokens</strong>. That is Obsidian, the level above Graphite.</p></div>
              <span className="gengen-material gengen-material-obsidian">Obsidian <span>100B</span></span>
            </div>
            <div className="gengen-path">
              <span className="gengen-path-number" aria-hidden="true">02</span>
              <div><h3>Two months after Graphite.</h3><p>Reach <strong>10 billion lifetime tokens</strong>, then wait <strong>two calendar months</strong> from the recorded Graphite crossing date.</p></div>
              <span className="gengen-material gengen-material-graphite">Graphite <span>10B</span></span>
            </div>
            <p className="gengen-eligibility-note">An unknown Graphite date stays unknown. Builder Nutch never invents a crossing date. The 100B path remains available. Changing the period or project you share does not reset your lifetime progress.</p>
            <a className="quiet-link" href={asset('ai-podium/#levels')}>Explore all nine levels <ArrowUpRight size={16} /></a>
          </div>
        </section>

        <section className="gengen-process shell" id="history" aria-labelledby="gengen-process-title">
          <div className="gengen-section-intro">
            <p className="eyebrow">START WITH WHAT YOU ALREADY DID</p>
            <h2 id="gengen-process-title">Your history<br />comes with you.</h2>
          </div>
          <ol className="gengen-steps">
            <li><span aria-hidden="true">01</span><div><h3>Install Builder Nutch.</h3><p>Download the Mac app. Open Usage to recover the Claude Code and Codex session records still on your Mac, including archived Codex sessions.</p></div></li>
            <li><span aria-hidden="true">02</span><div><h3>Let your history count.</h3><p>Available records from before installation can count. Keep working while the app is closed; it catches up when reopened. Captured token history is saved locally, separately from the original sessions.</p></div></li>
            <li><span aria-hidden="true">03</span><div><h3>Earn it. Share the work.</h3><p>When either path is met, GenGen joins your AI Podium. Open Share, choose a period or project, then copy or save the image. You decide where and when to post it.</p></div></li>
          </ol>
        </section>

        <section className="gengen-scope shell" aria-labelledby="gengen-scope-title">
          <p className="eyebrow">A CLEAR RECORD</p>
          <h2 id="gengen-scope-title">Local history. Visible limits.</h2>
          <div className="gengen-scope-copy">
            <p>The score counts recorded input, cache and output tokens from Claude Code and Codex. Reasoning is included in output, never added twice. Missing readings are not invented; partial totals remain marked. Deleted records that were never captured cannot be recovered.</p>
            <div><p>GenGen is generated from history saved on your Mac. It is not a server-signed credential or an independent assessment of your work. The counting is open to inspection; share the context with the label.</p><a className="quiet-link" href="https://github.com/Connected-Mate/builder-nutch/tree/main/Sources/Insights">Read how measurement works <ArrowUpRight size={16} /></a></div>
          </div>
        </section>

        <section className="gengen-download shell" aria-labelledby="gengen-download-title">
          <p className="eyebrow">LET THE WORK SPEAK</p>
          <h2 id="gengen-download-title">Show your score.<br />Show what you built.</h2>
          <p>Recover your activity. Earn your stamp. Put the numbers beside the work.</p>
          <div className="gengen-download-actions"><a className="button" href={download}><Download size={18} /> Get my AI Podium</a><a className="quiet-link" href={asset('ai-podium/')}>See AI Podium <ArrowUpRight size={16} /></a></div>
          <span className="gengen-download-note">Free &amp; open source · For Mac · Sharing is your choice</span>
        </section>
      </main>
      <footer className="shell">
        <a className="podium-wordmark" href={asset('gengen/')}>GenGen<span>generative generation</span></a>
        <div className="footer-links"><a href={asset('')}>Builder Nutch <ArrowUpRight size={14} /></a><a href={asset('ai-podium/')}>AI Podium <ArrowUpRight size={14} /></a><a href="https://github.com/Connected-Mate/builder-nutch">GitHub <ArrowUpRight size={14} /></a></div>
        <p className="legal">© 2026 Connected Mate · Built on Codenotch by Vinz.</p>
      </footer>
    </div>
  );
}
