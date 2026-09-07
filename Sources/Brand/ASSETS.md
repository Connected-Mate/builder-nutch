# Builder Nutch brand asset sources

Collected 2026-09-07. Assets are served from `public/`; this document records their original sources. Files are unmodified downloads except `logos/claude.svg`:
it contains only the official sun mark path extracted verbatim from Claude's
embedded wordmark and uses that path's original `0 0 125 125` bounds. No path
coordinates or fill were changed. Asset provenance is recorded below. Only the primary nine marks, the Latin WOFF2, and their applicable license notices are shipped by this site.

## Provider marks

| File | Exact source | Provenance and use note |
|---|---|---|
| `logos/claude.svg` | https://claude.com/ | Official standalone Claude sun mark extracted as described above; exact orange path preserved. Anthropic retains all trademark and copyright rights. |
| `logos/openai.svg` (same mark used for Codex and ChatGPT) | https://raw.githubusercontent.com/openai/openai-cookbook/main/examples/agents_sdk/deployment_manager/frontend/src/openai-logomark.svg | Official OpenAI repository, square monochrome `currentColor`; repository MIT license copied. OpenAI's mark terms: https://openai.com/brand/ |
| `logos/kimi.svg` | https://raw.githubusercontent.com/MoonshotAI/Branding-Guide/main/scenarios/04-k-only/k-only-light.svg | Official MoonshotAI branding repository, supplied K mark for light backgrounds. No separate asset license is present in that repository; Kimi/Moonshot trademarks remain theirs. |
| `logos/cursor.svg` | https://cursor.com/marketing-static/favicon.svg | Official Cursor website favicon SVG; supplied artwork retained exactly. Cursor retains trademark rights. |
| `logos/grok.svg` | https://grok.com/images/favicon.svg | Official Grok website favicon SVG; supplied current artwork retained exactly. SpaceXAI requires unchanged use and accurate reference: https://x.ai/legal/brand-guidelines |
| `logos/gemini.svg` | https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons/googlegemini.svg | Monochrome Google Gemini mark from Simple Icons (CC0-1.0), whose catalog references the Google Gemini product. Community-curated asset; Google retains trademark rights. |
| `logos/perplexity.svg` | https://www.perplexity.ai/favicon.svg | Official Perplexity website favicon SVG, downloaded directly. Perplexity retains trademark and copyright rights. |
| `logos/deepseek.svg` | https://fe-static.deepseek.com/chat/favicon.svg | Official DeepSeek chat site's square favicon mark, downloaded directly and unchanged. DeepSeek retains trademark rights. |
| `logos/mistral.svg` | https://raw.githubusercontent.com/mistralai/platform-docs-public/main/public/brand/m-rainbow.svg | Official Mistral documentation repository's compact rainbow M mark, unchanged; repository Apache-2.0 license copied. Mistral says not to alter or recolor its marks: https://mistral.ai/brand/ |

Open-source repository licenses do not waive provider trademark rules or imply
endorsement. Use marks only to identify the corresponding supported service,
keep them subordinate to Builder Nutch branding, and preserve their geometry.

## Bricolage Grotesque

| File | Exact source | Note |
|---|---|---|
| `fonts/bricolage-grotesque.woff2` | https://fonts.gstatic.com/s/bricolagegrotesque/v9/3y996as8bTXq_nANBjzKo3IeZx8z6up5L-iNGfyOPPs.woff2 | Official Google Fonts Latin web subset; variable weight 200–800 and width 75%–100%. |
| `fonts/OFL.txt` | https://raw.githubusercontent.com/google/fonts/main/ofl/bricolagegrotesque/OFL.txt | SIL Open Font License 1.1; retain this license with redistributed font files. |

Google Fonts CSS endpoint used to verify the WOFF2 variable ranges:
https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wdth,wght@12..96,75..100,200..800&display=swap

## Included license copies

- `fonts/OFL.txt` — SIL OFL 1.1.
- `licenses/Simple-Icons-CC0.md` — CC0-1.0 plus trademark reminder.
- `licenses/OpenAI-Cookbook-MIT` — MIT.
- `licenses/Mistral-Platform-Docs-License` — Apache-2.0.

## Native application resources

Native service marks are copied without geometry changes into `Sources/Assets.xcassets/brand-*.imageset`. The dark Kimi variant comes from https://raw.githubusercontent.com/MoonshotAI/Branding-Guide/main/scenarios/04-k-only/k-only-dark.svg. Font: the official Google Fonts Bricolage Grotesque variable TTF, with `Sources/Fonts/OFL.txt`. The application icon is the neutral typographic `bn.` wordmark rendered with this font, matching the website identity.

The icon can be regenerated with `Scripts/render-app-icon.swift`.
