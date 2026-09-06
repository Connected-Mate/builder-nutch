import { useRef, useState } from 'react';
import {
  ArrowDown,
  ArrowRight,
  ArrowUpRight,
  Check,
  ChevronDown,
  Download,
  Plus,
  Settings2,
  ShieldCheck,
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
const examples = [
  {
    name: 'Personal',
    detail: 'Limit reached · resets in 42 min',
    remaining: 0,
  },
  { name: 'Client projects', detail: 'Resets in 3 h 18 min', remaining: 81 },
  { name: 'Experiments', detail: 'Resets in 2 h 06 min', remaining: 64 },
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

function QuotaRing({ remaining }: { remaining: number }) {
  const circumference = 138.23;
  return (
    <span className="quota-ring" aria-label={`${remaining}% remaining`}>
      <svg viewBox="0 0 52 52" aria-hidden="true">
        <circle className="ring-track" cx="26" cy="26" r="22" />
        <circle
          className="ring-value"
          cx="26"
          cy="26"
          r="22"
          strokeDasharray={circumference}
          strokeDashoffset={circumference * (1 - remaining / 100)}
        />
      </svg>
      <span>
        {remaining}
        <small>%</small>
      </span>
    </span>
  );
}

function AccountPreview() {
  const [providerIndex, setProviderIndex] = useState(0);
  const [chosen, setChosen] = useState([0, 0, 0]);
  const [showProviders, setShowProviders] = useState(false);
  const addAssistantRef = useRef<HTMLButtonElement>(null);
  const providerRefs = useRef<(HTMLButtonElement | null)[]>([]);
  const provider = providers[providerIndex];
  const selected = chosen[providerIndex];
  function selectAccount(index: number) {
    setChosen((previous) =>
      previous.map((value, position) =>
        position === providerIndex ? index : value,
      ),
    );
  }
  return (
    <div className="preview-wrap" id="preview">
      <div className="preview-annotation">
        <span>One home for your AI accounts.</span>
        <span>
          TRY THE PREVIEW <ArrowDown size={13} />
        </span>
      </div>
      <div className="product-preview">
        <div className="window-bar">
          <span className="window-dots" aria-hidden="true">
            <i />
            <i />
            <i />
          </span>
          <span>Builder Nutch</span>
          <span className="sample-tag">Interactive example</span>
        </div>
        <div className="manager">
          <aside className="manager-sidebar" aria-label="Example assistants">
            <div className="sidebar-label">
              Your assistants <span>3</span>
            </div>
            <div className="provider-buttons">
              {providers.slice(0, 3).map((item, index) => (
                <button
                  key={item.id}
                  ref={(node) => {
                    providerRefs.current[index] = node;
                  }}
                  className={
                    index === providerIndex
                      ? 'provider-button active'
                      : 'provider-button'
                  }
                  onClick={() => {
                    setProviderIndex(index);
                    setShowProviders(false);
                  }}
                  aria-pressed={index === providerIndex}
                >
                  <ProviderLogo id={item.id} />
                  <span>{item.label}</span>
                  <span className="profile-count">3</span>
                </button>
              ))}
            </div>
            <button
              ref={addAssistantRef}
              className="add-assistant"
              onClick={() => setShowProviders(!showProviders)}
              aria-expanded={showProviders}
              aria-controls="preview-content"
            >
              <Plus size={16} /> Add assistant
            </button>
            <span className="sidebar-bottom">
              <ShieldCheck size={15} /> On your Mac. In your control.
            </span>
          </aside>
          <div className="manager-content" id="preview-content">
            {showProviders ? (
              <div className="provider-catalog">
                <div className="manager-heading">
                  <div>
                    <h2>Add an assistant</h2>
                    <p>
                      Choose a service. Sign in on its official page in the Mac
                      app.
                    </p>
                  </div>
                  <button
                    className="back-button"
                    onClick={() => {
                      setShowProviders(false);
                      addAssistantRef.current?.focus();
                    }}
                  >
                    Back
                  </button>
                </div>
                <div className="catalog-list">
                  {providers.map((item, index) => (
                    <div className="catalog-item" key={item.id}>
                      <ProviderLogo id={item.id} />
                      <span>
                        <strong>{item.label}</strong>
                        <small>{item.kind}</small>
                      </span>
                      {index < 3 ? (
                        <button
                          onClick={() => {
                            setProviderIndex(index);
                            setShowProviders(false);
                            providerRefs.current[index]?.focus();
                          }}
                          aria-label={`Preview ${item.label}`}
                        >
                          Preview <ArrowRight size={14} />
                        </button>
                      ) : (
                        <span className="catalog-availability">
                          In the Mac app
                        </span>
                      )}
                    </div>
                  ))}
                </div>
                <p className="catalog-note">
                  This website uses sample accounts. Download the app to connect
                  your own.
                </p>
              </div>
            ) : (
              <>
                <div className="manager-heading">
                  <div>
                    <div className="provider-title">
                      <ProviderLogo id={provider.id} size={25} />
                      <h2>{provider.label}</h2>
                    </div>
                    <p>Three accounts. Ready for your next session.</p>
                  </div>
                  <span className="account-total">3 accounts</span>
                </div>
                <div className="table-labels" aria-hidden="true">
                  <span>ACCOUNT</span>
                  <span>REMAINING</span>
                  <span>NEXT SESSION</span>
                </div>
                <div className="account-rows">
                  {examples.map((account, index) => (
                    <div
                      className={`account-row ${selected === index ? 'selected' : ''}`}
                      key={account.name}
                    >
                      <div className="account-identity">
                        <span className="account-avatar" aria-hidden="true">
                          {['P', 'C', 'E'][index]}
                        </span>
                        <span>
                          <strong>{account.name}</strong>
                          <small>{account.detail}</small>
                        </span>
                      </div>
                      <QuotaRing remaining={account.remaining} />
                      <button
                        className="select-account"
                        onClick={() => selectAccount(index)}
                        aria-pressed={selected === index}
                        aria-label={`Select ${account.name} for ${provider.label}`}
                      >
                        {selected === index ? (
                          <>
                            <Check size={14} /> Selected
                          </>
                        ) : (
                          <>
                            Use account <ArrowRight size={14} />
                          </>
                        )}
                      </button>
                    </div>
                  ))}
                </div>
                <div className="auto-select">
                  <div>
                    <Settings2 size={17} />
                    <span>
                      <strong>Put available quota to work.</strong>
                      <small>
                        Choose the account with the most room for the next
                        session.
                      </small>
                    </span>
                  </div>
                  <button
                    onClick={() =>
                      selectAccount(
                        examples.reduce(
                          (best, item, index) =>
                            item.remaining > examples[best].remaining
                              ? index
                              : best,
                          0,
                        ),
                      )
                    }
                  >
                    Try auto-select <ArrowRight size={15} />
                  </button>
                </div>
                <output className="preview-status">
                  <span className="status-dot" />
                  Next {provider.label} session:{' '}
                  <strong>{examples[selected].name}</strong>
                  <span className="example-only">Sample data</span>
                </output>
              </>
            )}
          </div>
        </div>
      </div>
      <p className="preview-footnote">
        A hands-on example, with sample accounts. Your real accounts stay in the
        Mac app.
      </p>
    </div>
  );
}

const faqs = [
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
    'Codex and Kimi Code read usage through their official local tools. Claude Code supplies usage after a managed session has been used. For browser profiles, check usage on the service’s website. Browser profiles are excluded from automatic selection.',
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
              <span className="status-dot" /> BUILT FOR PEOPLE WHO BUILD
            </p>
            <h1 id="hero-title">
              All your AI.
              <br />
              <span>Room to build.</span>
            </h1>
          </div>
          <div className="hero-copy">
            <p>Your next idea shouldn’t wait on one account.</p>
            <p>
              Bring your AI subscriptions together. See what’s available. Pick
              an account and get back to the work that matters.
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
          <AccountPreview />
        </section>
        <section
          className="workflow shell"
          id="how-it-works"
          aria-labelledby="workflow-title"
        >
          <div className="section-intro">
            <span className="eyebrow">
              LESS ACCOUNT ADMIN. MORE ACTUAL WORK.
            </span>
            <h2 id="workflow-title">
              From sign-in
              <br />
              to shipping.
            </h2>
            <p>
              A few subscriptions. A lot of possibilities.
              <br />
              Keep the setup out of your way.
            </p>
          </div>
          <ol className="steps">
            <li>
              <span className="step-number">01</span>
              <div>
                <h3>Your service. Your login.</h3>
                <p>
                  Click <strong>Add assistant</strong>, choose the provider, and
                  sign in on its official page. No hunting for tokens. No
                  password forms here.
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
            <div
              className="edge-illustration"
              aria-label="Illustration of the auto-hidden notch"
            >
              <span className="edge-screen-label">
                YOUR WORK, FRONT AND CENTER
              </span>
              <div className="edge-line" />
              <div className="mini-notch">
                <ProviderLogo id="claude" size={22} />
                <span>
                  81<small>%</small>
                </span>
                <ProviderLogo id="openai" size={22} />
                <span>
                  64<small>%</small>
                </span>
              </div>
              <span className="edge-hint">
                <ArrowUpRight size={19} /> Right where you need it.
              </span>
            </div>
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
            <span className="eyebrow">YOUR IDEAS DESERVE THE ATTENTION</span>
            <h2 id="principles-title">
              Experiment more.
              <br />
              Make something real.
            </h2>
          </div>
          <div className="principles-copy">
            <p>
              AI subscriptions are a way to try the ambitious idea, explore a
              new direction and ship useful work. Get more from the ones you
              already have.
            </p>
            <p>
              Builder Nutch stays small: accounts on your Mac, official sign-in,
              open source. Just a little less friction between you and your next
              build.
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
          <span className="eyebrow">LESS SWITCHING. MORE SHIPPING.</span>
          <h2 id="download-title">Go build the thing.</h2>
          <p>Your subscriptions, together. Your next idea, closer.</p>
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
