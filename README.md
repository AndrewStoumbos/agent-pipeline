# agent-pipeline

A reusable **builder → reviewer** agent pipeline for GitHub Actions, built on
[Claude Code](https://code.claude.com/docs/en/github-actions).

One agent writes the code and opens a pull request. Automated checks run. A second, independent
agent reviews the PR and leaves inline comments. If it finds real problems, the builder fixes
them, up to a limit. A human always makes the final merge.

All the logic lives in this repo. Each project only gets a small trigger workflow
(`.github/workflows/agent.yml`) and a settings file (`.agent-pipeline.yml`) that says how to
set up, lint and test it. It works for any language you can build on a GitHub runner.

```
issue labeled "agent:build"           PR opened / pushed by a human
          │                                      │
          ▼                                      │
  BUILDER agent                                  │
  branch agent/issue-N, commits, opens PR        │
          │                                      │
          └──────────────► GATES ◄───────────────┘
                 format · lint · tests · semgrep · gitleaks
                     │ fail                 │ pass
                     │                      ▼
                     │           REVIEWER agent
                     │           fresh session, read-only, JSON output
                     │                      │
                     ▼                      ▼
             ┌── changes needed? ── yes, rounds left, agent PR ──► BUILDER fixes ──► GATES …
             │
             ├── yes, out of rounds ──► label agent:needs-human
             └── no ──► "agent-review" status = success ──► YOU merge
```

---

## Contents

1. [How it works](#how-it-works)
2. [Choosing models](#choosing-models)
3. [One-time setup](#one-time-setup)
4. [Claude credentials](#claude-credentials)
5. [Adding a project](#adding-a-project)
6. [GitHub settings for each project](#github-settings-for-each-project)
7. [Day-to-day use](#day-to-day-use)
8. [Writing good issues](#writing-good-issues)
9. [`.agent-pipeline.yml` reference](#agent-pipelineyml-reference)
10. [Caching](#caching)
11. [Updating the pipeline](#updating-the-pipeline)
12. [Troubleshooting](#troubleshooting)
13. [Repo layout](#repo-layout)
14. [Things to know](#things-to-know)

---

## How it works

- **Independent reviewer.** The reviewer runs in a separate job with a fresh Claude Code
  session. It sees the diff, the PR text and the repo, but never the builder's conversation.
  Its tools are read-only (`Read`, `Glob`, `Grep`, `git diff/log/show`); editing and web access
  are disallowed.
- **Gates before the reviewer.** Format, lint, type checks, tests and security scans run
  first. If they fail, the reviewer is skipped (saving tokens) and the failures go straight back
  to the builder.
- **Structured review.** The reviewer returns JSON matching `schemas/review.json`
  (file, line, severity, category, issue, suggestion). Comments on changed lines are posted
  inline; general comments (line `0`, file `(general)`) go in the review summary. If the
  structured output goes missing, the pipeline recovers the review from the agent's final
  message.
- **The bar is set in config, not by the model.** A round fails only if a comment has a
  severity listed in `review.block_on` (default `blocker` and `major`).
- **Bounded loop.** `review.max_rounds` (default 3) caps the total number of review rounds.
  After that the PR gets the `agent:needs-human` label.
- **Humans merge.** The pipeline sets a commit status named `agent-review`. Branch protection
  requires it before merging. Agents never get merge rights.
- **Prompt-injection hygiene.** Issue text, PR text, diffs and feedback are written to files
  and labeled as untrusted data in the prompts. Nothing user-controlled is interpolated into
  shell commands. The builder can't push, can't call `gh`, and its run is rejected if it touches
  `.github/`.
- **No forks.** PRs from forks are skipped (no secrets, untrusted code).

---

## Choosing models

Models are set per project in `.agent-pipeline.yml`:

```yaml
models:
  builder: claude-sonnet-5-5
  reviewer: claude-opus-5-5
```

Using a **different, stronger model** for the reviewer means the checker doesn't share every
blind spot of the author. Pick based on how you pay:

| You pay with | Builder | Reviewer | Notes |
|---|---|---|---|
| Claude **Pro** subscription | `claude-sonnet-5-5` | `claude-opus-5-5` | Fable models are not included in Pro's usage limits; they need usage credits. |
| Claude **Max** subscription | `claude-opus-5-5` | `claude-fable-5-1` | Fable 5.1 is included on Max. |
| **API key** (pay per token) | `claude-opus-5-5` | `claude-fable-5-1` | Fable is the most capable and most expensive. |

The built-in defaults (used when a key is missing from your config) are `claude-opus-5-5` for
the builder and `claude-fable-5-1` for the reviewer, so **Pro users must set `models.reviewer`
explicitly**. Otherwise the reviewer fails with "Fable 5.1 requires usage credits".

Current model IDs and prices: https://platform.claude.com/docs/en/models/overview

---

## One-time setup

1. **Create this repo on GitHub and make it public**, for example `YOUR-USER/agent-pipeline`.
   It contains no secrets. (GitHub Desktop defaults to *private*: uncheck "Keep this code
   private" when publishing, or change it later under Settings → General → Danger Zone →
   Change visibility.)

   Using a private repo instead is possible: Settings → Actions → General → Access →
   "Accessible from repositories owned by the user", **and** a fine-grained token with read
   access to this repo saved in each project as the secret `PIPELINE_REPO_TOKEN`.

2. **Push the files and tag a version.** Projects use `@v1`, so you can change `main` freely
   and only move the tag when you're ready:
   ```bash
   git init -b main
   git add .
   git commit -m "Agent pipeline v1"
   git remote add origin https://github.com/YOUR-USER/agent-pipeline.git
   git push -u origin main
   git tag v1
   git push origin v1
   ```

3. **Check it from GitHub's side.** On the repo page, the top level should show `.github`,
   `actions`, `prompts`, `schemas`, `scripts`, `templates` (not a single `agent-pipeline`
   folder), and the branch dropdown → **Tags** should list `v1`.

---

## Claude credentials

Each project needs **one** of these repository secrets. If both are set, the subscription
token is used.

| Secret | What it is | Billing |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Token for your Claude subscription (Pro, Max, Team, Enterprise), from `claude setup-token`. Valid for one year. | Counts against your plan's usage limits, shared with your normal Claude use. |
| `ANTHROPIC_API_KEY` | API key from https://platform.claude.com | Pay per token. Best for repos other people push to. |

### Getting a subscription token

`claude setup-token` is a Claude Code command. Having the Claude desktop app isn't enough;
install the command-line tool:

| System | Install command |
|---|---|
| Windows PowerShell | `irm https://claude.ai/install.ps1 \| iex` |
| Windows CMD | `curl -fsSL https://claude.ai/install.cmd -o install.cmd && install.cmd && del install.cmd` |
| macOS / Linux / WSL | `curl -fsSL https://claude.ai/install.sh \| bash` |

Open a **new** terminal and check it with `claude --version`.

> **Windows: "not in your PATH".** If the installer says `C:\Users\<you>\.local\bin` is not in
> your PATH, run this in PowerShell, then close and reopen every terminal:
> ```powershell
> [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";$env:USERPROFILE\.local\bin", "User")
> ```

Then, in a normal terminal (not inside a Claude Code session):
```bash
claude setup-token
```
Approve in the browser and copy the token it prints. **It isn't saved anywhere**, so paste it
straight into the project's secret (see below).

With a subscription token:
- **Limits can stall a run.** If you hit your usage limit mid-run, that job fails; re-run it
  later. Keep `max_turns` and `max_rounds` modest.
- **It's tied to you.** Only put it in repos you control. If it leaks, run
  `claude setup-token` again and replace the secret.

---

## Adding a project

### Option A: `install.sh` (macOS, Linux, WSL, Git Bash)

```bash
cd agent-pipeline
export CLAUDE_CODE_OAUTH_TOKEN=...     # or ANTHROPIC_API_KEY=sk-ant-...
./install.sh ../my-project rust --github
```

This writes `.github/workflows/agent.yml` and `.agent-pipeline.yml` into the project. With
`--github` it also creates the labels, sets the credential secret, and allows Actions to open
PRs (requires the `gh` CLI).

Templates: `python`, `node`, `go`, `rust`, `java`, `dotnet`, `cpp`, and `cpp-node`
(C++ backend + JS frontend in one repo). For anything else, start from any template, set
`language: none`, and install tools in `setup`.

### Option B: by hand (Windows without bash)

1. Copy `templates/agent.yml` to `<project>/.github/workflows/agent.yml`. **Use `agent.yml`, not
   `agent-build.yml` or `agent-review.yml`**: those are this repo's internal workflows and never
   start on their own.
2. In that file, replace every `__PIPELINE_REPO__` with `YOUR-USER/agent-pipeline` and every
   `__PIPELINE_REF__` with `v1`.
3. Copy the matching `templates/configs/<language>.yml` to `<project>/.agent-pipeline.yml`.

### Then, for either option

1. **Edit `.agent-pipeline.yml`** so `setup` and `gates` match how the project really builds,
   and set `models` for your plan (see [Choosing models](#choosing-models)).
2. **Make sure every gate passes on the default branch first.** If `main` is already failing,
   every agent round fails for reasons unrelated to the PR. Running the formatter once usually
   fixes most of it.
3. **Add a `CLAUDE.md`** at the project root: layout, how to build and test, conventions, and
   rules (for example "never log the API key", "tests must not hit the network"). Both agents
   read it.
4. **Commit and push** to the default branch (before turning on branch protection).

Optional, for Windows users: add a `.gitattributes` containing `* text=auto eol=lf` so files
use LF line endings everywhere and Git stops warning "LF will be replaced by CRLF".

---

## GitHub settings for each project

In the project repo on github.com:

1. **Secret.** Settings → Secrets and variables → Actions → New repository secret:
   `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`).
2. **Let Actions open PRs.** Settings → Actions → General → Workflow permissions → check
   **Allow GitHub Actions to create and approve pull requests** → Save.
3. **Trigger label.** Issues → Labels → New label: `agent:build`. (The pipeline creates
   `agent` and `agent:needs-human` itself. `agent:skip-review` is optional.)
4. **Auto-delete branches.** Settings → General → Pull Requests → check
   **Automatically delete head branches**.
5. **Protect the default branch.** Settings → Rules → Rulesets → New branch ruleset:

   | Setting | Value |
   |---|---|
   | Enforcement status | Active |
   | Target branches | Include default branch |
   | Bypass list | empty |
   | Require a pull request before merging | on |
   | Required approvals | **0** if you work alone (GitHub won't let you approve your own PRs; your merge click is the sign-off), 1+ for teams |
   | Require review from specific teams | **off** (needs an organization) |
   | Allowed merge methods | **Squash** |
   | Require status checks to pass | on, add **`agent-review`** |
   | Block force pushes / Restrict deletions | on |

   GitHub only suggests status checks it has seen recently, so add `agent-review` after the
   pipeline has run once. Don't require your other CI checks: they don't run on agent commits
   (see [Things to know](#things-to-know)).

   After this, nobody can push straight to the default branch, including you. All changes,
   including changes to the pipeline files, go through a PR.

---

## Day-to-day use

| You do | Pipeline does |
|---|---|
| Add label `agent:build` to an issue | Builder implements it on `agent/issue-N`, opens a PR, review starts |
| Open or push to a PR yourself | Gates + reviewer comment on it (no automatic fixes unless `auto_fix: all`) |
| Add label `agent:skip-review` to a PR | Pipeline ignores that PR |
| Actions → **agent** → Run workflow (mode `review`, PR number, branch = the PR's branch) | Re-runs a review by hand |
| See `agent:needs-human` on a PR | Rounds ran out or something errored; take over the PR |

**Where to watch:** the repo's **Actions** tab. A label-triggered run shows a **build** job.
Then a second run shows **review / prepare → gates → review → finalize**. The PR gets an
`agent-review` check and a review comment. A typical round takes 5–15 minutes.

**One branch per change.** Start each change from an up-to-date default branch and let the
branch be deleted after merging:
```bash
git switch master && git pull
git switch -c short-description
# edit, commit
git push -u origin short-description
```
Reusing an old branch after a squash merge makes GitHub show it as "N commits ahead" (its
original commits were squashed into a new one) and "behind" grows with every merge. That's
cosmetic, but it's a sign to start a fresh branch.

**If the builder refuses to start** with "Branch agent/issue-N already exists", merge or close
the old PR for that issue and delete its branch, then re-add the label.

---

## Writing good issues

The builder treats an issue as a task, so anything works: features, refactors, tests, docs.
Size each issue like **one pull request**. Each run has a turn cap and a 60-minute timeout,
and the reviewer judges the PR against what the issue asked for.

```markdown
**Look up liked movies on TMDB**

For each movie in `liked_movies.toml`, search TMDB by title (and year if given) and
return the best match.

- Add a `search_movie(title, year)` method to the TMDB client
- If there's no match, skip it and print a warning; don't fail the run
- Tests use JSON fixtures, no network calls

Out of scope: scoring changes.
```

- **Say what's out of scope.** It keeps the builder focused and stops the reviewer flagging
  things you didn't ask for.
- **Break big features into steps** and label them one at a time when they touch the same code;
  two agent PRs editing the same files will conflict.
- **Make the design decisions yourself** (frameworks, architecture, data model). Agents are good
  at implementing a decision, weaker at making product or architecture calls.
- **The agents never get your app's own secrets** (API keys etc.), so anything that needs a live
  external API must be testable with fixtures or mocks.

---

## `.agent-pipeline.yml` reference

| Key | Default | Meaning |
|---|---|---|
| `language` | `none` | Toolchain to install: `python`, `node`, `go`, `rust`, `java`, `dotnet`, `none` |
| `version` | per language | Toolchain version |
| `setup` | `""` | Shell commands run before gates and agents (install dependencies) |
| `gates` | `[]` | List of `{name, run, timeout?}`; any non-zero exit fails the round |
| `security.semgrep` | `true` | Semgrep `p/default` on changed code only |
| `security.gitleaks` | `true` | Secret scan on the PR's new commits |
| `models.builder` | `claude-opus-5-5` | Builder model |
| `models.reviewer` | `claude-fable-5-1` | Reviewer model (**Pro plans: change this**) |
| `builder.max_turns` | `60` | Turn cap for the builder (cost control) |
| `builder.allowed_commands` | the gate commands | Shell commands the builder may run, Claude Code syntax (`"cargo test:*"`) |
| `review.max_turns` | `30` | Turn cap for the reviewer |
| `review.max_rounds` | `3` | Total review rounds before escalating (3 = up to 2 automatic fix rounds) |
| `review.block_on` | `[blocker, major]` | Severities that fail a round |
| `review.auto_fix` | `agent_prs` | Who gets automatic fixes: `agent_prs`, `all`, `never` |
| `review.ignore_paths` | `[]` | Glob patterns whose review comments are dropped (e.g. `Cargo.lock`) |
| `review.focus` | `""` | Extra project-specific instructions for the reviewer |

**Monorepos:** every gate gets `$AGENT_BASE_SHA` (the PR's base commit), so a gate can skip
parts of the tree the PR didn't touch:
```yaml
- name: frontend-tests
  run: |
    if git diff --quiet "$AGENT_BASE_SHA...HEAD" -- frontend/; then echo "skipping"; exit 0; fi
    npm --prefix frontend test
```
See `templates/configs/cpp-node.yml` for a full example.

---

## Caching

GitHub-hosted runners are fresh machines every run, so the pipeline caches the slow parts:

- **Rust:** downloaded crates and the compiled `target/` folder, shared by the builder, fixer
  and gates.
- **Node / Python / Go / Java:** each setup action's built-in dependency cache, when the
  project has a lockfile.
- **Semgrep:** installed once into a cached folder.

Caches flow **from the default branch down to PRs**. A build run (started by labeling an issue)
runs on the default branch and fills the cache for every later PR. Review and fix rounds inside
a PR reuse it. Expect the first run after a dependency change to be slower. GitHub clears
caches that go unused for 7 days.

Still done every run, but quick: installing Claude Code itself and pulling the gitleaks image.

---

## Updating the pipeline

Projects run whatever `v1` points to. After changing files here:

```bash
git add -A
git commit -m "Describe the change"
git push
git tag -f v1            # move v1 to the new commit
git push -f origin v1
```

`git push -f origin v1` should print `(forced update)`. If the tag doesn't move, projects keep
running the old version even though `main` looks right.

To re-test after an update, start a **fresh** run (re-add the issue label, or close and reopen
the PR) rather than "Re-run jobs".

For breaking changes, create a `v2` tag instead and move projects over one at a time.

---

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| Nothing appears in Actions after labeling | The trigger file is missing or misnamed in the project | Check the project's `.github/workflows/` contains **`agent.yml`** (not `agent-build.yml`), committed to the default branch. The label must be exactly `agent:build`; re-add it after fixing |
| `Invalid workflow file … reference to workflow should be either a valid branch, tag, or commit` | The pipeline repo is private, misnamed, or has no `v1` tag on GitHub | Make the repo public; `git push origin v1`; check the `uses:` lines in `agent.yml` |
| `fatal: tag 'v1' already exists` | The tag exists locally | That's fine; run `git push origin v1` (or `git tag -f v1` + `git push -f origin v1` to move it) |
| Builder agent fails after ~15 s: `Claude execution failed: result is_error:true` | No usable credential reached Claude | Check the secret name (`CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`), and that `v1` points at a version with subscription support |
| `Unexpected value '3'` on the `pr_number` line | Old `agent.yml` (dispatch inputs arrive as text) | Update the project's `agent.yml` from `templates/agent.yml`. Branches created before the fix still have the old file: click **Update branch** on their PR |
| `Fable 5.1 requires usage credits` (in the "Post review" step log) | Your plan doesn't include Fable | Set `models.reviewer: claude-opus-5-5` (see [Choosing models](#choosing-models)) |
| `--json-schema was provided but Claude did not return structured_output` | The reviewer finished without returning its review | The pipeline now recovers it from the final message. If it still fails, the log prints the reviewer's last message, which explains why |
| Reviewer step finishes in under ~30 seconds | The model replied with an error instead of reviewing | Open **Post review on the PR** in the log and read "Reviewer's final message" |
| Runs on agent PRs show **Action required** | GitHub holds workflows on bot-opened PRs for approval | Ignore the `agent` one (the pipeline starts its own review). Approve your normal CI if you want it to run |
| `push declined due to repository rule violations` | Branch protection is on | Push to a branch and open a PR. In an emergency, set the ruleset's enforcement to Disabled, push, then set it back to Active |
| Builder: `Branch agent/issue-N already exists` | A previous run for that issue left its branch | Merge or close that PR and delete the branch, then re-add the label |
| Branch shows "N commits ahead / M behind" after merging | Squash merge creates a new commit; the branch is stale | Delete the branch and start a new one from the default branch |
| `LF will be replaced by CRLF` warnings on Windows | Git's line-ending conversion | Harmless. To silence it, add `.gitattributes` with `* text=auto eol=lf` |
| Run log says "Sign in to view logs" | Logs need a GitHub login, even on public repos | Sign in to github.com, then open the run |

---

## Repo layout

```
.github/workflows/agent-build.yml   reusable: builder (mode build | fix)
.github/workflows/agent-review.yml  reusable: prepare → gates → review → finalize
actions/setup-toolchain/            composite action: language toolchain, caches, project setup
prompts/                            builder.md, fixer.md, reviewer.md
schemas/review.json                 reviewer's required output format
scripts/pipeline.py                 config, gates, posting reviews, statuses (Python stdlib only)
templates/agent.yml                 per-project trigger workflow
templates/configs/*.yml             per-language .agent-pipeline.yml starters
install.sh                          copies the templates into a project
```

---

## Things to know

- **Agent pushes don't trigger your other CI.** Pushes and PRs made with the workflow's
  `GITHUB_TOKEN` don't start other workflows (GitHub's loop protection), so the pipeline chains
  its own steps with `workflow_dispatch`. Your separate CI only runs on agent PRs if you approve
  it by hand. The pipeline's gates run the same checks, so this is usually fine. If you need
  your CI on every agent commit, push with a GitHub App token
  (`actions/create-github-app-token`) in `agent-build.yml` instead.
- **Cost.** Each round is one reviewer run, and each fix is one builder run. Turn caps,
  `max_rounds`, skipping the reviewer when gates fail, and one-run-at-a-time per PR keep spend
  bounded. With an API key, set a spend limit on your Anthropic workspace as a backstop.
- **Workflow changes stay with you.** The builder can't edit `.github/`; runs that touch it are
  rejected.
- **Measure it.** Track how often you dismiss reviewer comments and how many bugs reach the
  default branch anyway, then tune `prompts/reviewer.md`, `review.focus` and `block_on`.
