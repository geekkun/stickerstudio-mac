<!-- ASSEMBLED BY META-REPO — Do not edit shared sections manually -->
<!-- Layers: shared lang/swift, -->

<!-- LAYER:shared:START -->
# Shared Conventions

## Git

- Commit messages: `type: short description` (feat, fix, refactor, docs, ci, chore)
- Branch naming: `type/short-description` or `phase-N-description`
- Squash merge to the default branch and keep GitHub's commit list in the message (the version's PATCH counts it). A repo that already uses merge commits keeps them.
- **Push after EVERY commit. No exceptions.** Sessions can be interrupted — unpushed work is permanently lost.
- **Commit after each meaningful unit of work**, not after all tasks are done. Never accumulate more than ~30 minutes of uncommitted work.
- A "meaningful unit" = one logical change that doesn't break the build. Exception: files that must change together go in one commit.
- **Merge your own PRs** once review findings are fixed and CI is green. If a merge deploys, take the backup the project's CLAUDE.md asks for first. Stop and hand over only when a PR needs something only the owner can do (a BotFather setting, a secret, a payment), or when the project's CLAUDE.md says otherwise.
- **Merge-as-you-go: one PR at a time.** Branch each phase from up-to-date `main`; when it's done and CI is green, merge it, then branch the next phase from the updated default branch. **Never stack PRs** — don't branch a phase off an unmerged phase branch (it chains the PRs, pollutes each diff with the previous phase, and forces rebase cascades). If work must continue before a merge, keep it on one evolving branch/PR, not a stack.
- **NEVER force-push** or amend published commits unless explicitly asked.
- **No destructive git.** Never run commands that discard uncommitted changes (`reset`, `checkout .`, `clean`, `restore .`, `stash drop/clear`, etc.). Add on top of staged files — don't nuke the index. When in doubt, ask.
- **Ask before destroying what you didn't create:** `rm -rf` outside your own scratch or build files, killing processes you didn't start, dropping databases, anything on a production box beyond the project's documented deploy steps. Approval for one such action doesn't cover the next.
- **Commit instead of stashing.** Never stash to rebase: commit WIP, fetch, rebase, continue. At most one stash ever.

## Working Style

### Shortest Path First
- **ALWAYS lead with the quickest, simplest option.** Present the one-liner first. Put the longer alternative after, labeled "alternatively".
- When giving commands, consolidate into as few copy-paste blocks as possible.

### Planning First
- Plan complex work before writing code: a spec, then a plan, both committed. When something goes sideways, stop and re-plan instead of pushing a broken approach.

### Use Subagents
- Use subagents for parallel independent work (searching, reading files, implement + review).
- **Size the fan-out to the work.** Mostly sequential work gets 2–3 agents, usually one implementer and one reviewer. Clearly distinct tasks can run 5–6 at once. Never more: 15 parallel agents on guest-bot burned a week's usage limit in about a day. Never run two agents that edit the same file. A project's CLAUDE.md or plan may set a lower cap.
- **Keep every agent's context small** — each tool call re-sends all of it (guest-bot agents hit 200–500k tokens per task and the account limit mid-batch): grep and ranged reads, never whole large files; quiet targeted tests while working, the full suite once before the PR, never paste full logs; screenshots only for UI changes; high-effort review only for risky PRs (migrations, auth, money, privacy). Pattern: guest-bot `docs/cloud-sessions.md` «Working efficiently».

### After Every Correction
- When the user corrects a mistake, update the relevant CLAUDE.md so it doesn't recur.

### Persist Intermediate Work
- **Specs and plans** → `docs/superpowers/specs/` and `docs/superpowers/plans/`, `YYYY-MM-DD-<topic>.md`, committed (where the superpowers skills write them)
- **Ephemeral agent thinking** (reviews, brainstorming, session state) → `tmp/` (gitignored)
- Context compression destroys conversation history; persisted files survive.
- Big ideas and improvements that won't be done now → create GitHub issues so they're not forgotten.

### Splitting work across sessions (pattern: guest-bot)
- Three kinds of session, glued by GitHub Issues: the **local CLI session** (the only one with box access — data, merges, coordination), a **desktop visual-QA session** (Chrome + iOS Simulator, never touches code; files one issue per problem with the repo's issue forms), and **cloud sessions** that each take ONE issue labelled `ready` and not `in-progress`, comment «taking this», add `in-progress`, and ship a PR that says `Closes #N`.
- `ready` = specified enough to pick up, added by the organizer or the main session, never by QA. Keep the two briefs in the repo (`docs/cloud-sessions.md`, `docs/qa/README.md`) so a fresh session needs no chat history.

### Multi-Persona Reviews
- For major changes, run multiple agent perspectives (code reviewer, SRE, end-user, product) to find blind spots.
- Save each persona's output to `tmp/` or `docs/reviews/`, then synthesize into actionable items.

## Report Back to Meta (two-way sync)

Everything above the PROJECT section comes from the meta-repo (`geekkun/meta`); it is only as good as what flows back. **Report upstream when you:**
- **deviate** from a meta rule in this repo (e.g. a different deploy flow, a skipped CI step);
- **find a rule wrong, outdated or missing** (a gotcha that bit you, a cost you paid);
- **adopt new tech or a pattern** another repo could reuse (a library, a CI trick, a Docker/Caddy setup, a test approach).

**How:** one issue per item, in the same session, without waiting to be asked:
`gh issue create -R geekkun/meta --label upstream --title "<repo>: <one line>" --body "<what> / <why — the bug, cost or owner's call> / <where — file + PR link> / <proposal: shared or which layer, or project-only>"`.
- Every item needs a **reason**. "We prefer X" with no cost or bug behind it stays project-only and is not filed.
- **Search first:** `gh issue list -R geekkun/meta --state all --search "<keywords>"` and grep the layers. If it's covered, comment on that issue (e.g. a simpler variant) instead of filing a new one.
- **It must change what another repo's session would do.** State it in one sentence without this repo's names. If you can't, it's project-only. A library gotcha counts only when its failure is silent and costly.
- **Propose the exact text** (1–3 lines) and an existing layer: `shared`, `lang/<python|typescript|swift>` or `platform/<web|telegram-bot|ios|android>`. Implementation detail stays in this repo, referenced as `Pattern: <repo> <file>`.
- A deviation also goes in this repo's PROJECT section as `**Deviates from meta:** <rule> — <reason> (meta#N)`, so sync never "fixes" it back and the audit can find it.
- Never edit the synced sections above PROJECT in this repo: the next sync overwrites them. Change the rule in meta, or record the deviation.
- No `gh` or no network (cloud sandbox, offline): append the same fields to `docs/meta-feedback.md` and commit it; the meta audit collects it.

## Versioning

**The version is computed from git, never typed in. No agent bumps anything, so parallel PRs never conflict over it.**
- **MINOR = PRs merged on the default branch**, **PATCH = that PR's commits** (a direct push to the default branch adds one). On an unmerged branch: the default branch's MINOR at the merge-base + 1. MAJOR = a deliberate edit of the script's anchor.
- The project ships `scripts/version.sh [<rev>]` (POSIX sh, git only) that prints it. Pattern: guest-bot `scripts/version.sh` + `tests/test_version_script.py`; set its main-branch name, anchor commit and anchor MINOR when copying.
- **The deploy writes it** to a file on the data volume (e.g. `data/VERSION`; images carry no `.git`), and the app reads that file once at startup — `0.0.0` when missing. No version line in the code, no pre-commit hook.
- CI checks out full history (`fetch-depth: 0`) and fails if the script can't print a version. Squash merges keep GitHub's default commit list in the message (that's where PATCH comes from).
- **This overrides any "bump PATCH/MINOR by hand" or pre-commit-hook rule** left in a project's CLAUDE.md or sub-CLAUDE.md files. Delete such a rule when you see one.
- **A project still on a hand-written `VERSION`:** migrating is its own PR (anchor = the default-branch tip it branches from, anchor MINOR = the current MINOR). Until that PR merges, don't bump in a feature PR at all — leave the line alone and let the migration replace it. If an old bump hook is installed, commit with `--no-verify` or remove it from `.git/hooks`.

## Changelog

No changelog section in `CLAUDE.md`. **Each PR adds one file `docs/changes/YYYY-MM-DD-<topic>.md`** — what changed, why, the names a later session will grep for, the tests that pin it — with **no version number** (git knows it only at merge; the PR number and date place it). New files never conflict. `CLAUDE.md` holds what is true now (rules, gotchas), not history; a new rule goes there too. Pattern: guest-bot `docs/changes/README.md`.

## Code Review

- **One issue = one GH comment.** Never group multiple issues into one comment.
- **Post every finding you verified.** Post an unverified one too, labelled as unverified, instead of dropping it. Don't pad a review with style nits the linter already covers.

## Code Quality

- Meaningful variable names, no unnecessary abbreviations
- Type hints / type annotations everywhere applicable
- Docstrings / JSDoc for public functions
- Keep functions small and focused
- Prefer explicit over implicit
- **Never blindly retry a call with side effects** (registers, issues a code, charges). Retry only when the request provably never left: connect timeout, DNS failure, connection refused. A read timeout, a reset after sending or a bad response = one attempt, and the user is told to try again later. Pattern: imperiya_grez `core/api.py` `_never_sent`.

## Security

- Secrets in `.env` file, gitignored. Never commit tokens or keys.
- Bot tokens, API keys, SECRET_KEY — environment variables only.
- Input validation at all boundaries.
- **Screenshots, GIFs and demos for docs or QA never show real people.** Run the app on a fresh data dir seeded with invented records, kept fresh so it never refreshes from the real API. Pattern: imperiya_grez `docs/changes/2026-10-11-guide-screenshots.md`.

## Docker

- Build from the official slim images (`python:3.13-slim` / `python:3.14-slim`), multi-stage for production.
- Everything runs in Docker: tests, lockfile regeneration, one-off scripts.
- **A root container writing into a host-owned bind mount** (`data/`): an atomic write via `mkstemp` + `os.replace` leaves a 0600 root file, the deploy user's pre-deploy backup `tar` can't read it, and every deploy stops. `chmod 0644` the temp file, `chown` it to the data dir's owner when euid is 0, then replace; sweep stale `*.tmp` under the same lock.

## CI/CD

- GitHub Actions for all projects
- Shared workflow templates in `shared/.github/workflows/`
- **CI (PR):** lint with ruff → Docker build (Buildx + GHA cache) → import verify → tests, in **one job** (each job is billed rounded up to a whole minute). `concurrency` keyed by PR number, `cancel-in-progress` for PRs only (a main run is the deploy gate). Build the runtime image only on main.
- **The runner is a switch, not a rewrite:** `runs-on: ${{ fromJSON(vars.CI_RUNS_ON || '"ubuntu-latest"') }}` in CI and Deploy. `gh variable set CI_RUNS_ON --body '["self-hosted","<label>"]'` moves both to the owner's machine (free minutes, warm Docker cache: guest-bot 1 m 33 s vs 5 m 46 s); deleting the variable moves back. A job aimed at an offline runner waits up to 24 h: flip the variable. **Private repos only:** a self-hosted runner runs every PR's code as the runner user.
- **Self-hosted gotchas:** `~` is the owner's home, so the deploy key and known_hosts go under `$RUNNER_TEMP` (trap-removed), never `~/.ssh`; `actions/setup-python` fails on any Mac but GitHub's (skip it when `runner.environment == 'self-hosted'`, use host Python in a `$RUNNER_TEMP` venv); buildx `driver: docker` with empty GHA cache inputs; prune only the CI's own images by label (`docker image prune -f --filter label=<repo>-ci=1`). Detail: `docs/references/self-hosted-runner.md`.
- **Deploy (push to main):** build + test → SSH to VPS → `git pull && docker compose up -d --build` → health check
- `paths-ignore`: `**/*.md`, `docs/**`, `.claude/**`, `.gitignore`, `LICENSE` (and `tests/**` on deploy). A bare `*.md` matches only the repo root, so a docs-only PR touching a package's `CLAUDE.md` still deploys.
- Required GitHub Secrets for deploy: `VPS_SSH_KEY`, `VPS_HOST`, `VPS_USER`, `VPS_PORT`, `DEPLOY_PATH`, plus `VPS_KNOWN_HOSTS` (the shared deploy template warns and falls back to `accept-new` without it)
- **Fill `VPS_KNOWN_HOSTS` from the box itself:** `cat /etc/ssh/ssh_host_*_key.pub` over an SSH session you already trust, fingerprints checked against your local known_hosts, stored as `* <type> <key>` lines (the `*` works whatever `VPS_HOST` holds). The deploy uses `StrictHostKeyChecking=yes`. Never `ssh-keyscan` the shared box (its rate limit blocked port 22) and never `accept-new` on a fresh runner (it verifies nothing).
- Django projects: add migration check (`makemigrations --check --dry-run`) to CI
- Next.js projects: artifact-based deploy with PM2 process manager
<!-- LAYER:shared:END -->

<!-- LAYER:lang/swift:START -->
# Swift

## Runtime
- Swift 6+, strict concurrency checking

## Style & Tooling
- Swift Package Manager for dependencies
- Prefer `struct` over `class` unless reference semantics needed
- Use `async/await` over completion handlers
- Leverage the type system — avoid `Any` and force unwrapping
- Naming: camelCase for types and properties (e.g., `bankModel`, `cardModel`)
- Logger: `OSLog` with app bundle ID as subsystem

## Architecture
- MVVM or similar separation
- Protocol-oriented design where appropriate
- Use `@Observable` macro (iOS 17+)
- WidgetKit for home screen widgets (small/medium/large)
- UserNotifications for reminders

## Localization
- Russian primary, English in progress
- Use `Localizable.xcstrings` for all user-facing strings
<!-- LAYER:lang/swift:END -->

<!-- PROJECT:START — Everything below is project-specific and preserved during sync -->

# Project-Specific

_Add project-specific guidelines, architecture notes, and context here._

<!-- PROJECT:END -->
