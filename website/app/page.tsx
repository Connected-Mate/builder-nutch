import { useState } from 'react';
import {
  ArrowDown,
  ArrowRight,
  ArrowUpRight,
  Check,
  ChevronDown,
  Download,
  Plus,
} from 'lucide-react';

const repository = 'https://github.com/Connected-Mate/builder-nutch';
const download = `${repository}/releases/latest`;
const asset = (path: string) => `${import.meta.env.BASE_URL}${path}`;
const providers = [
  {
    id: 'claude',
    name: 'Claude',
    label: 'Claude Code',
    kind: 'Coding accounts',
  },
  { id: 'openai', name: 'OpenAI', label: 'Codex', kind: 'Coding accounts' },
  { id: 'kimi', name: 'Kimi', label: 'Kimi Code', kind: 'Coding accounts' },
  { id: 'cursor', name: 'Cursor', label: 'Cursor', kind: 'Browser profile' },
  { id: 'grok', name: 'Grok', label: 'Grok', kind: 'Browser profile' },
  { id: 'chatgpt', name: 'ChatGPT', label: 'ChatGPT', kind: 'Browser profile' },
  { id: 'gemini', name: 'Gemini', label: 'Gemini', kind: 'Browser profile' },
  {
    id: 'perplexity',
    name: 'Perplexity',
    label: 'Perplexity',
    kind: 'Browser profile',
  },
  {
    id: 'deepseek',
    name: 'DeepSeek',
    label: 'DeepSeek',
    kind: 'Browser profile',
  },
  { id: 'mistral', name: 'Mistral', label: 'Mistral', kind: 'Browser profile' },
];
function ProviderLogo({ id, size = 24 }: { id: string; size?: number }) {
  return (
    <img
      className="provider-logo"
      src={asset(`logos/${id === 'chatgpt' ? 'openai' : id}.svg`)}
      alt=""
      width={size}
      height={size}
    />
  );
}

const screenshots = [
  {
    file: 'accounts.png',
    label: 'Your accounts',
    alt: 'Actual Builder Nutch Mac app showing connected Claude accounts and their live remaining subscription limits. Personal details are hidden.',
  },
  {
    file: 'assistants.png',
    label: 'Add an assistant',
    alt: 'Actual Builder Nutch Mac app provider picker with official service logos and connection options.',
  },
  {
    file: 'codex.png',
    label: 'Codex',
    alt: 'Actual Builder Nutch Mac app showing a connected Codex subscription and its remaining quota. Personal details are hidden.',
  },
];

function AppScreenshots() {
  const [selected, setSelected] = useState(0);
  const screenshot = screenshots[selected];
  return (
    <figure className="preview-wrap app-screenshots" id="preview">
      <div className="preview-annotation">
        <span>One home for your AI accounts.</span>
        <span>
          THE REAL MAC APP <ArrowDown size={13} />
        </span>
      </div>
      <div className="screenshot-picker" aria-label="App screenshots">
        {screenshots.map((item, index) => (
          <button
            key={item.file}
            type="button"
            aria-pressed={selected === index}
            onClick={() => setSelected(index)}
          >
            {item.label}
          </button>
        ))}
      </div>
      <a
        className="screenshot-frame"
        href={asset(`screenshots/${screenshot.file}`)}
        target="_blank"
        rel="noreferrer"
        aria-label={`Open full-size screenshot: ${screenshot.label}`}
      >
        <img
          src={asset(`screenshots/${screenshot.file}`)}
          alt={screenshot.alt}
          width={3024}
          height={1898}
          fetchPriority="high"
        />
      </a>
      <figcaption>
        Captured in Builder Nutch for macOS. Personal details hidden.{' '}
        <a
          href={asset(`screenshots/${screenshot.file}`)}
          target="_blank"
          rel="noreferrer"
        >
          View full size <ArrowUpRight size={12} />
        </a>
      </figcaption>
    </figure>
  );
}

const faqs = [
  [
    'What is AI Podium?',
    'AI Podium turns your recorded Claude Code and Codex activity into a shareable image: token totals for today, this calendar week or this month, plus the AI assistants you used most today. You can also focus on a single project. Input, cache and output are included; reasoning is part of output, not added twice. Incomplete readings stay marked.',
  ],
  [
    'What does my AI Podium share?',
    'The image shows token totals, dates and your AI ranking. Account names and conversations stay private. A project name appears only when you select a project and personal details are visible. Copy or save the image, then attach it to your post on X or LinkedIn. The optional 17:30 notification opens today’s preview; it does not publish for you.',
  ],
  [
    'Will it find accounts already on my Mac?',
    'Yes. Builder Nutch checks the usual Claude Code, Codex and Kimi Code profile locations and adds confirmed signed-in accounts. It reuses the original sign-in without copying tokens. Previously linked profiles and verified duplicate identities are skipped; removed profiles stay removed. Kimi can show separate profiles for the same subscription when its tool does not provide account identity. Browser subscriptions need their own sign-in; browser cookies are not scanned.',
  ],
  [
    'Can I add six accounts from the same service?',
    'Yes. Create a separate profile for every account you want to use. There is no six-account cap. Choose your service, sign in on its official page, then add a nickname and emoji if you like.',
  ],
  [
    'What happens when an account reaches its limit?',
    'With automatic selection enabled, the next session you launch from Builder Nutch uses an eligible account from the same provider with the most fresh, verified quota. Accounts at their limit, with stale usage or without a connection are skipped. Running conversations keep their existing account.',
  ],
  [
    'Which services can I connect?',
    'Claude Code, Codex and Kimi Code support isolated coding accounts. Grok, ChatGPT, Gemini, Perplexity, DeepSeek, Mistral and the Cursor dashboard use separate browser profiles. Cursor’s desktop editor and other standalone desktop apps keep their own logins.',
  ],
  [
    'Will I see usage for every account?',
    'Codex and Kimi Code read usage through their official local tools. Recent Claude Code versions can read plan limits without sending a message. When a service does not return limits, the app shows them as unavailable. For browser profiles, check usage on the service’s website. Browser profiles are excluded from automatic selection.',
  ],
  [
    'Does Builder Nutch give me extra AI usage?',
    'Every subscription keeps its own limits and terms. Builder Nutch helps you put the accounts you already pay for to work. It does not increase quotas or transfer a running conversation between accounts.',
  ],
  [
    'Where do my logins go?',
    'Sign-in happens through the official coding tool or an isolated browser profile on your Mac. Builder Nutch does not ask you to paste passwords or authentication tokens. The marketing website has no access to your accounts.',
  ],
];

export default function Home() {
  return (
    <>
      <a href="#main" className="skip-link">
        Skip to content
      </a>
      <header className="site-header shell">
        <a
          className="wordmark"
          href={import.meta.env.BASE_URL}
          aria-label="Builder Nutch home"
        >
          builder nutch<span aria-hidden="true">.</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#how-it-works">How it works</a>
          <a href="#ai-podium">AI Podium</a>
          <a href={repository} className="github-link">
            GitHub <ArrowUpRight size={15} />
          </a>
          <a href={download} className="button button-small">
            Get the Mac app <ArrowUpRight size={15} />
          </a>
        </nav>
      </header>
      <main id="main">
        <section className="hero shell" aria-labelledby="hero-title">
          <div className="hero-heading">
            <p className="eyebrow">
              <span className="status-dot" /> BUILT FOR HIGH-OUTPUT AI BUILDERS
            </p>
            <h1 id="hero-title">
              Build more.
              <br />
              <span>While AI is still this affordable.</span>
            </h1>
          </div>
          <div className="hero-copy">
            <p>
              Today’s AI subscriptions give builders an extraordinary amount
              of intelligence for a monthly price.
            </p>
            <p>
              Bring the plans you pay for together, keep available capacity
              visible and turn more experiments into production. With AI Podium,
              share your token activity and the AI behind your day.
            </p>
            <div className="hero-actions">
              <a className="button" href={download}>
                <Download size={17} /> Download for Mac
              </a>
              <a className="quiet-link" href="#preview">
                Take a look <ArrowDown size={16} />
              </a>
            </div>
            <span className="compatibility">
              Free &amp; open source · macOS 26+
            </span>
          </div>
          <div className="provider-strip" aria-label="Supported services">
            {providers.map((item) => (
              <div key={item.id} title={item.name}>
                <ProviderLogo id={item.id} size={25} />
                <span>{item.name}</span>
              </div>
            ))}
          </div>
          <AppScreenshots />
        </section>
        <section className="podium-section shell" id="ai-podium" aria-labelledby="podium-title">
          <div className="podium-intro">
            <span className="eyebrow">AI PODIUM</span>
            <h2 id="podium-title">Your day.<br />Your AI Podium.</h2>
            <p>
              You built something. Show the AI behind it. Your token totals and
              most-used assistants, together in one image, ready for X or LinkedIn.
            </p>
            <ul className="podium-features">
              <li><Check size={17} /> Today, this week, this month — or one project</li>
              <li><Check size={17} /> Today’s top AI, ranked by recorded tokens</li>
              <li><Check size={17} /> A daily reminder at 17:30 to share your day</li>
            </ul>
            <a className="quiet-link" href={download}>
              Make your AI Podium <ArrowUpRight size={16} />
            </a>
          </div>
          <figure className="podium-preview">
            <a href={asset('screenshots/ai-podium.png')} target="_blank" rel="noreferrer"
              aria-label="View a full-size AI Podium example">
              <img src={asset('screenshots/ai-podium.png')} width={2400} height={1260}
                loading="lazy" alt="AI Podium example exported from Builder Nutch: token totals on the left and today’s AI ranking with provider logos on the right, on a black background lit in the leading AI’s colors." />
            </a>
            <figcaption>Example data · Exported from the Mac app · 2400 × 1260 PNG</figcaption>
          </figure>
        </section>
        <section
          className="workflow shell"
          id="how-it-works"
          aria-labelledby="workflow-title"
        >
          <div className="section-intro">
            <span className="eyebrow">
              MORE CAPACITY. MORE SHIPPED WORK.
            </span>
            <h2 id="workflow-title">
              Use today’s
              <br />
              pricing advantage.
            </h2>
            <p>
              A few subscriptions can unlock a serious R&amp;D pace.
              <br />
              Keep every plan ready for the next build.
            </p>
          </div>
          <ol className="steps">
            <li>
              <span className="step-number">01</span>
              <div>
                <h3>Your service. Your login.</h3>
                <p>
                  Already signed in on your Mac? Claude Code, Codex and Kimi
                  Code accounts are detected automatically. To add another,
                  click <strong>Add assistant</strong> and sign in on its
                  official page.
                </p>
                <span className="step-detail">
                  <Plus size={14} /> Choose → Sign in → You’re in
                </span>
              </div>
            </li>
            <li>
              <span className="step-number">02</span>
              <div>
                <h3>Make every account familiar.</h3>
                <p>
                  Work, personal, the next experiment. Add a nickname and an
                  emoji after connecting, so the right account is always easy to
                  find.
                </p>
                <span className="step-detail">
                  <Check size={14} /> One account, one clear identity
                </span>
              </div>
            </li>
            <li>
              <span className="step-number">03</span>
              <div>
                <h3>Launch with room to work.</h3>
                <p>
                  Pick an account in one click, or let available quota guide
                  your next coding session. Existing sessions keep their
                  account.
                </p>
                <span className="step-detail">
                  <ArrowRight size={14} /> Available quota → Next session
                </span>
              </div>
            </li>
          </ol>
        </section>
        <section className="edge-section" aria-labelledby="edge-title">
          <div className="shell edge-layout">
            <figure className="appearance-capture">
              <a
                href={asset('screenshots/appearance.png')}
                target="_blank"
                rel="noreferrer"
                aria-label="Open the actual Mac appearance settings screenshot"
              >
                <img
                  src={asset('screenshots/appearance.png')}
                  width={1280}
                  height={1424}
                  loading="lazy"
                  alt="Actual Builder Nutch appearance settings, with auto-hide and screen edge options."
                />
              </a>
              <figcaption>Your Mac app. Your preferred screen edge.</figcaption>
            </figure>
            <div className="edge-copy">
              <span className="eyebrow">THERE WHEN YOU NEED IT</span>
              <h2>
                Out of sight.
                <br />
                Still on your side.
              </h2>
              <p>
                Keep your workspace yours. Auto-hide makes the notch disappear
                until your pointer reaches the screen edge — left, right, top or
                bottom.
              </p>
              <p className="small-copy">
                Your assistants keep working while it’s tucked away.
              </p>
            </div>
          </div>
        </section>
        <section
          className="principles shell"
          aria-labelledby="principles-title"
        >
          <div>
            <span className="eyebrow">THIS WINDOW WILL NOT STAY OPEN FOREVER</span>
            <h2 id="principles-title">
              Use affordable intelligence.
              <br />
              Ship valuable products.
            </h2>
          </div>
          <div className="principles-copy">
            <p>
              Buying the same volume through direct API or enterprise plans can
              cost far more. Individual subscriptions make intensive
              experimentation unusually accessible today. Use that advantage
              to test ambitious ideas, move faster and put the winners into
              production.
            </p>
            <p>
              Builder Nutch keeps every plan visible and ready on your Mac.
              Subscribe within each provider’s terms, build aggressively and
              make the monthly cost earn its place in shipped work.
            </p>
            <a className="quiet-link" href={repository}>
              See the source on GitHub <ArrowUpRight size={16} />
            </a>
          </div>
        </section>
        <section className="faq shell" aria-labelledby="faq-title">
          <div>
            <span className="eyebrow">A FEW GOOD QUESTIONS</span>
            <h2 id="faq-title">
              Before you
              <br />
              get building.
            </h2>
          </div>
          <div className="faq-list">
            {faqs.map(([question, answer]) => (
              <details key={question}>
                <summary>
                  {question}
                  <Plus className="faq-plus" size={19} />
                  <ChevronDown className="faq-chevron" size={19} />
                </summary>
                <p>{answer}</p>
              </details>
            ))}
          </div>
        </section>
        <section
          className="download-section shell"
          aria-labelledby="download-title"
        >
          <span className="eyebrow">THE BEST TIME TO BUILD IS NOW</span>
          <h2 id="download-title">Use the window. Ship the product.</h2>
          <p>Turn today’s AI pricing into tomorrow’s production software.</p>
          <a className="button" href={download}>
            <Download size={18} /> Get Builder Nutch for Mac
          </a>
          <span className="compatibility">
            macOS 26+ · Apple Silicon &amp; Intel · Free &amp; open source
          </span>
        </section>
      </main>
      <footer className="shell">
        <div>
          <a className="wordmark" href={import.meta.env.BASE_URL}>
            builder nutch<span aria-hidden="true">.</span>
          </a>
          <p>
            Built on{' '}
            <a href="https://github.com/vinzdg/codenotch">Codenotch by Vinz</a>.
            Made for your next build.
          </p>
        </div>
        <div className="footer-links">
          <a
            href="https://x.com/AlexCormeraie"
            target="_blank"
            rel="noreferrer"
            aria-label="Follow Alex Cormeraie on X"
          >
            X · @AlexCormeraie <ArrowUpRight size={14} />
          </a>
          <a href={repository}>
            Source <ArrowUpRight size={14} />
          </a>
          <a href={`${repository}/releases`}>
            Releases <ArrowUpRight size={14} />
          </a>
        </div>
        <p className="legal">
          © 2026 Connected Mate · MIT license. Independent project. All provider
          names and logos belong to their respective owners.
        </p>
      </footer>
    </>
  );
}
