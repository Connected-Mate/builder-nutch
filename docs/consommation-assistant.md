# Consommation — l'assistant qui explique où part ton quota

*Spec produit. Public : le propriétaire de Builder Nutch. Annexe technique en anglais à la fin.*

## But

Builder Nutch dit **combien** il reste (« 73 % »), jamais **pourquoi**.
« Consommation » répond à la vraie question : *qu'est-ce qui a mangé mon quota, quand, et sur quel compte.*
Puis on lui confie un compte : il pose quelques questions et rend un plan de travail qui tient dans les limites, preuves à l'appui.
Tout se calcule sur le Mac. Aucun texte de conversation ne sort de la machine.

## Ce que l'utilisateur verra

**1. Un onglet « Consommation » dans la fenêtre des comptes.**
En haut, une phrase en français simple, pas un tableau :
> « Cette semaine, 62 % de ton quota est parti dans *Citizen Creators*, surtout mardi soir entre 21 h et minuit. »

En dessous, trois blocs :

- **Le classement.** Les projets triés par part du quota, avec une barre. Un clic ouvre les sessions : le titre déjà écrit par Claude (« Compte déconnecté bloqué dans builder-nudge »), l'heure, la durée, la part.
- **Le rythme.** Une bande de 7 jours, une case par heure, plus foncée quand elle a coûté cher. Trait rouge sur les fenêtres de 5 h épuisées. C'est là qu'on voit « je me crame toujours le mardi soir ».
- **Par compte.** La même chose compte par compte, avec la mention honnête quand l'attribution est incertaine.

**2. Une ligne dans le notch, au survol.** Une seule phrase : *« 5 h : 41 % — surtout Balaye depuis 14 h. »*

**3. L'assistant « Confie-moi ce compte ».** Un bouton sur chaque compte ouvre une conversation courte :
6 questions max, lecture de ce qui existe en local, puis **un plan** — quel compte pour quoi, à quelles heures,
quand il basculera tout seul, ce qu'il faut arrêter de faire. Chaque affirmation renvoie à la session qui la justifie.

## Questions à poser à l'utilisateur (6 max, avec la réponse recommandée)

| # | Question | Réponse recommandée par défaut |
|---|---|---|
| 1 | On regarde tes conversations locales pour expliquer la consommation ? | **Oui, et elles restent sur le Mac** — sans ça, la fonction n'existe pas. |
| 2 | Quelle période par défaut ? | **7 jours**, aligné sur la limite hebdomadaire. |
| 3 | On regroupe par projet (dossier) ou par sujet (titre de session) ? | **Par projet**, avec les sujets en second niveau. |
| 4 | On utilise ton abonnement pour faire résumer les sujets par l'IA ? | **Non par défaut.** Les titres existent déjà gratuitement. À activer à la demande, une fois par semaine max. |
| 5 | Quels comptes l'assistant a-t-il le droit de faire basculer ? | **Ceux déjà en rotation**, aucun nouveau sans accord. |
| 6 | Quelles heures veux-tu protéger (garder du quota disponible) ? | **9 h–19 h en semaine** — le reste est du temps libre. |

## Sources de données et fiabilité

| Source | Ce qu'elle donne | Fiabilité |
|---|---|---|
| Conversations locales (`~/.claude/projects/**`) | projet, horodatage, jetons par message, modèle, session | **Élevée** pour le *classement relatif*. Ce ne sont pas des pourcentages officiels. |
| Titre de session déjà calculé | le sujet, en français, gratuit | **Élevée**, et zéro coût de quota. |
| `~/.claude/history.jsonl` | ce qui a été demandé, mot pour mot | Élevée, mais texte sensible → jamais affiché sans clic. |
| API d'usage (déjà branchée) | le **vrai** pourcentage des fenêtres 5 h / semaine / par modèle | **Source officielle.** C'est elle qui donne les totaux. |
| Rattachement à un compte | identifiant de compte présent dans certaines sessions ; sinon dossier de profil ; sinon compte actif à cette heure-là | **Partielle** : environ 1 session sur 9 le porte aujourd'hui. Le reste est déduit. L'écran le dit. |

Le principe qui tient tout : **les jetons locaux donnent les parts, l'API donne le total.**
On répartit le pourcentage officiel entre les projets au prorata de leur poids local. On n'invente jamais un pourcentage.

## Plan de réalisation (tranches d'une heure, par valeur décroissante)

1. **Lecteur local** — sort projet / sujet / heure / poids des conversations, avec cache disque. Aucune UI. *(fait)*
2. **Le classement** — l'onglet, la phrase du haut, le top des projets sur 7 jours.
3. **Journal de rotation** — enregistrer le compte actif à chaque bascule (aujourd'hui perdu à la fermeture). C'est ce qui rend l'attribution par compte crédible.
4. **Le rythme** — la bande 7 jours et les fenêtres épuisées.
5. **Détail d'un projet** — sessions, titres, durées, lien vers la conversation.
6. **La ligne du notch** — une phrase au survol.
7. **L'assistant** — les 6 questions, le plan, les preuves cliquables.
8. **Résumé IA optionnel** — sur demande, coût annoncé avant.

## Risques et limites

- **Vie privée.** Rien ne quitte le Mac. Le contenu lu est une donnée, jamais une consigne à exécuter.
- **Coût du résumé IA.** Il consomme le quota qu'on veut économiser → désactivé par défaut, coût annoncé avant.
- **Angles morts.** Ce qui vient d'ailleurs (app Claude, web, autre Mac) manque dans le détail mais pas dans le total. L'écart s'affiche comme « ailleurs », jamais masqué.
- **Estimation, pas facture.** L'app écrit « environ », pas un chiffre à la virgule.

---

## Technical appendix (EN)

**Inputs.** Session transcripts: `~/.claude/projects/<slug>/<sessionId>.jsonl`, plus per-profile copies under
`~/Library/Application Support/Codenotch Accounts/profiles/<uuid>/projects/` (isolation via `CLAUDE_CONFIG_DIR`,
set in `Sources/Accounts/AccountEnvironment.swift:10`). ~471 files locally.

**Per-line schema (verified).**
- `type:"assistant"` → `message.usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens_details.thinking_tokens}`, `message.model` (e.g. `claude-fable-5-1`), plus top-level `timestamp` (ISO-8601 Z), `sessionId`, `cwd`, `gitBranch`, `version`, `isSidechain`, `requestId`.
- `type:"ai-title"` → `aiTitle`, `sessionId`. Free, human-readable topic. Use it; do not re-summarize.
- `type:"bridge-session"` → `ownerAccountUuid`, `ownerOrganizationUuid`. Only 52/471 files carry it → partial account attribution.
- `~/.claude/history.jsonl` → `{display, timestamp(ms), project, sessionId}`.
- `isSidechain:true` marks subagent turns — count them, attribute to the parent session.

**Weighting.** Server-side quota weights are not published. Use a stated estimator, exposed in the UI as an estimate:
`w = input + output*5 + cache_creation*1.25 + cache_read*0.1`, times a model factor
(Haiku 0.25, Sonnet 1, Opus/Fable 5). `output_tokens_details.thinking_tokens` is a *subset* of `output_tokens`
and must not be added again. Normalize per window; multiply by the authoritative `usedFraction` from
`LimitWindow` (`Sources/Accounts/ClaudeAccountUsage.swift`) to get per-project percentages. Never sum raw tokens into a percentage.
Implemented in `Sources/Insights/UsageLedgerModels.swift` (`UsageWeight`); the cache carries a `formula`
number so a change to these factors invalidates every stored weight instead of mixing two scales.

**Window alignment.** `LimitWindow.resetsAt` anchors the rolling 5h/7d buckets; walk transcript timestamps into
`[resetsAt - windowLength, resetsAt)`. `UsageForecast` (`Sources/Accounts/UsageForecast.swift`) is in-memory by
design (12 samples, ~10 min) — it is a rotation hint, not history. Slice 3 adds a small append-only rotation
journal (account id + timestamp per switch, no content) next to the catalog in `AccountStorage`, which is what
makes time-based account attribution defensible.

**Cost control.** Index incrementally: store `(file, size, mtime, byteOffset)` and parse only the tail on refresh.
Full first index of ~470 files should stay under a second on a background queue; never on the main actor.

**Security.** Transcript text is untrusted input. Render titles and prompts as inert text, strip control characters,
cap lengths (see the existing `text(_:)` guard in `ClaudeAccountUsage.swift`), and never execute or forward anything found inside.
