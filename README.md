# agent-pipeline

A reusable builder → reviewer agent pipeline for GitHub Actions. One central repo holds all
the logic; each project only gets a 60-line caller workflow and a `.agent-pipeline.yml` that
says how to set up, lint and test it. Works for any language you can build on a GitHub runner.

```
issue labeled "agent:build"           PR opened / pushed by a human
          │                                      │
          ▼                                      │
  BUILDER agent (Opus 5.5)                       │
  branch agent/issue-N, commits, opens PR        │
          │                                      │
          └──────────────► GATES ◄───────────────┘
                 lint · typecheck · tests · semgrep · gitleaks
                     │ fail                 │ pass
                     │                      ▼
                     │          REVIEWER agent (Fable 5.1)
                     │          fresh context, read-only, JSON output
                     │                      │
                     ▼                      ▼
             ┌── changes needed? ── yes, rounds left, agent PR ──► BUILDER fixes ──► GATES …
             │
             ├── yes, out of rounds ──► label agent:needs-human
             └── no ──► "agent-review" status = success ──► HUMAN approves & merges
```

## Why these models

| Role | Default | Why |
|---|---|---|
| Builder | `claude-opus-5-5` | Anthropic positions Opus 5.5 for long-running agentic coding; $4 / $20 per M tokens in/out. |
| Reviewer | `claude-fable-5-1` | Fable 5.1 is the stronger reasoning model ($10 / $50). Using a different, stronger model for review means the checker doesn't share every blind spot of the author. |

Both are set per project in `.agent-pipeline.yml`, so a small side project can use
`claude-sonnet-5-5` for both while a production service keeps the defaults. Check current IDs
and prices at https://platform.claude.com/docs/en/models/overview.

## Design choices

- **Independent reviewer.** The reviewer runs in a separate job with a fresh Claude Code session.
  It sees the diff, the PR text and the repo, but never the builder's conversation. Its tools are
  read-only (`Read`, `Glob`, `Grep`, `git diff/log/show`); edits and web access are disallowed.
- **Gates before the reviewer.** Lint, type checks, tests and security scans run first. If they
  fail, the reviewer is skipped (saving tokens) and the failures go straight back to the builder.
- **Structured review.** The reviewer must return JSON matching `schemas/review.json`
  (file, line, severity, category, issue, suggestion). `scripts/pipeline.py` posts each item as an
  inline PR comment; items outside the diff go into the review body.
- **The bar is set in config, not by the model.** A round fails only if a comment has a
  severity listed in `review.block_on` (default `blocker`, `major`).
- **Bounded loop.** `review.max_rounds` (default 3) caps total review rounds. After that the PR
  gets `agent:needs-human`.
- **Humans merge.** The pipeline sets a commit status named `agent-review`. Branch protection
  requires it plus a human approval. Agents never get merge rights.
- **Prompt-injection hygiene.** Issue text, PR text, diffs and feedback are written to files and
  labeled as untrusted data in the prompts. Nothing user-controlled is interpolated into shell
  commands. The builder can't push, can't call `gh`, and its run is rejected if it touches `.github/`.
- **No forks.** PRs from forks are skipped (no secrets, untrusted code).

## One-time setup

1. **Create this repo** on GitHub (for example `your-user/agent-pipeline`) and push these files.
2. **Tag a version:** `git tag v1 && git push origin v1`. Projects pin `@v1`, so you can change
   the pipeline on `main` without breaking them, then move the tag when ready.
3. **Let other repos use it.** If this repo is public, nothing to do. If private:
   Settings → Actions → General → Access → "Accessible from repositories owned by the user",
   **and** create a fine-grained PAT with read access to this repo, saved in each project as the
   secret `PIPELINE_REPO_TOKEN` (the workflows need it to check out the scripts).
4. **Pick a Claude credential** (see "Paying for it" below): a subscription token from
   `claude setup-token`, or an API key from https://platform.claude.com.

## Paying for it: subscription or API key

Each project needs ONE of these repository secrets. If both are set, the subscription token wins.

| Secret | What it is | Billing |
|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | Long-lived token for your Claude subscription (Pro, Max, Team, Enterprise). Run `claude setup-token` on your own machine and paste the result. | Counts against your plan's usage limits, shared with your normal Claude and Claude Code use. |
| `ANTHROPIC_API_KEY` | Claude API key from the Claude Console. | Pay per token. Best for shared/org repos. |

With a subscription token:
- **Check your plan's model access.** On Pro (and standard Team/Enterprise seats), Fable models
  are not part of the plan's limits and run on pay-as-you-go usage credits. If that's you, set
  `models.reviewer: claude-opus-5-5` (builder and reviewer can still be different settings and
  run in separate, independent sessions).
- **Limits can stall a run.** If you hit your usage limit mid-run, that job fails; re-run it
  later. Keep `max_turns` and `max_rounds` modest.
- **It's tied to you.** The token acts as your subscription, so only put it in repos you
  control, and revoke/regenerate it if it leaks. For repos other people push to, use an API key.

## Adding a project

```bash
cd agent-pipeline
export CLAUDE_CODE_OAUTH_TOKEN=...         # from `claude setup-token`; or ANTHROPIC_API_KEY=sk-ant-...
./install.sh ../my-project python --github
```

This writes `.github/workflows/agent.yml` and `.agent-pipeline.yml` into the project and, with
`--github`, creates the labels, sets the Claude credential secret, and allows Actions to open PRs. Then:

1. Edit `.agent-pipeline.yml` so `setup` and `gates` match how the project really builds.
   Tip: every gate should pass on `main` before you turn the pipeline on.
2. Optionally add a `CLAUDE.md` at the project root with conventions; both agents read it.
3. Commit and push to the default branch.
4. Turn on branch protection (below).

Templates exist for `python`, `node`, `go`, `rust`, `java`, `dotnet`, `cpp`, and `cpp-node` (C++ backend + JS frontend in one repo; gates skip whichever half a PR didn't touch using `$AGENT_BASE_SHA`). For anything
else, start from any template, set `language: none`, and install tools in `setup`.

### Branch protection

Settings → Branches (or Rules → Rulesets) for the default branch:
- Require a pull request with **1 approval**
- Require status check **`agent-review`**
- Do not allow bypass

Or with `gh` (classic protection):

```bash
gh api -X PUT repos/OWNER/REPO/branches/main/protection --input - <<'EOF'
{
  "required_status_checks": { "strict": true, "contexts": ["agent-review"] },
  "enforce_admins": true,
  "required_pull_request_reviews": { "required_approving_review_count": 1 },
  "restrictions": null
}
EOF
```

## Using it

| You do | Pipeline does |
|---|---|
| Add label `agent:build` to an issue | Builder implements it on `agent/issue-N`, opens a PR, review starts |
| Open or push to a PR yourself | Gates + reviewer comment on it (no automatic fixes unless `auto_fix: all`) |
| Add label `agent:skip-review` to a PR | Pipeline ignores that PR |
| Run the `agent` workflow manually (mode `review`, PR number) | Re-runs a review |
| See `agent:needs-human` | Rounds ran out or something errored; take over the PR |

## `.agent-pipeline.yml` reference

| Key | Default | Meaning |
|---|---|---|
| `language` | `none` | Toolchain to install: python, node, go, rust, java, dotnet, none |
| `version` | per language | Toolchain version |
| `setup` | `""` | Shell commands run before gates and agents (install deps) |
| `gates` | `[]` | List of `{name, run, timeout?}`; any non-zero exit fails the round |
| `security.semgrep` | `true` | Semgrep `p/default` on changed code only |
| `security.gitleaks` | `true` | Secret scan on the PR's new commits |
| `models.builder` | `claude-opus-5-5` | Builder model |
| `models.reviewer` | `claude-fable-5-1` | Reviewer model |
| `builder.max_turns` | `60` | Claude Code turn cap for the builder (cost control) |
| `builder.allowed_commands` | the gate commands | Shell commands the builder may run, Claude Code syntax (`"pytest:*"`) |
| `review.max_turns` | `30` | Turn cap for the reviewer |
| `review.max_rounds` | `3` | Total review rounds before escalating (3 = up to 2 automatic fix rounds) |
| `review.block_on` | `[blocker, major]` | Severities that fail a round |
| `review.auto_fix` | `agent_prs` | Who gets automatic fixes: `agent_prs`, `all`, `never` |
| `review.ignore_paths` | `[]` | Glob patterns whose review comments are dropped |
| `review.focus` | `""` | Extra project-specific instructions for the reviewer |

## Repo layout

```
.github/workflows/agent-build.yml   reusable: builder (mode build | fix)
.github/workflows/agent-review.yml  reusable: prepare → gates → review → finalize
actions/setup-toolchain/            composite action: install language + run setup
prompts/                            builder.md, fixer.md, reviewer.md
schemas/review.json                 reviewer's required output format
scripts/pipeline.py                 config, gates, posting reviews, statuses (stdlib only)
templates/agent.yml                 per-project caller workflow
templates/configs/*.yml             per-language .agent-pipeline.yml starters
install.sh                          copies templates into a project
```

## Things to know

- **Agent pushes don't trigger your other CI.** Pushes and PRs made with the workflow's
  `GITHUB_TOKEN` don't start other workflows (GitHub's loop protection), so the pipeline chains
  itself with `workflow_dispatch`. Your separate CI won't run on agent commits until a human
  pushes. If you need that, create a GitHub App, mint a token with
  `actions/create-github-app-token`, and use it for the push step in `agent-build.yml`.
- **Cost.** Each round is one reviewer run, and each fix is one builder run. Turn caps,
  `max_rounds`, skipping the reviewer when gates fail, and the `concurrency` group keep spend
  bounded. Set a spend limit on your Anthropic workspace as a backstop.
- **Reviewer refusals.** If the reviewer model ever declines part of a security review, switch
  `models.reviewer` to `claude-opus-5-5` for that project.
- **Measure it.** Track how often humans dismiss reviewer comments and how many bugs reach `main`
  anyway, then tune `prompts/reviewer.md` and `block_on`.
