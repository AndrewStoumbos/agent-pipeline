#!/usr/bin/env bash
# Install the agent pipeline into a project repository.
#
#   ./install.sh <project-dir> <language> [--ref v1] [--repo owner/agent-pipeline] [--github]
#
#   language   python | node | go | rust | java | dotnet | cpp | cpp-node
#   --ref      tag/branch of agent-pipeline to pin (default: v1)
#   --repo     owner/name of this pipeline repo (default: read from this checkout's origin)
#   --github   also configure the GitHub side with `gh`: labels, the Claude credential
#              secret (from $CLAUDE_CODE_OAUTH_TOKEN or $ANTHROPIC_API_KEY), and
#              "Allow GitHub Actions to create PRs"
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
project="${1:-}"; lang="${2:-}"
[[ -n "$project" && -n "$lang" ]] || { sed -n '2,11p' "$0"; exit 1; }
shift 2

ref="v1"; pipeline_repo=""; configure_github=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --repo) pipeline_repo="$2"; shift 2 ;;
    --github) configure_github=true; shift ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$pipeline_repo" ]]; then
  url="$(git -C "$here" remote get-url origin 2>/dev/null || true)"
  pipeline_repo="$(sed -E 's#(git@github\.com:|https://github\.com/)##; s#\.git$##' <<<"$url")"
  [[ "$pipeline_repo" == */* ]] || { echo "Can't detect the pipeline repo; pass --repo owner/agent-pipeline"; exit 1; }
fi

config_src="$here/templates/configs/$lang.yml"
[[ -f "$config_src" ]] || { echo "No config template for '$lang'. Options: $(ls "$here/templates/configs" | sed 's/\.yml//' | tr '\n' ' ')"; exit 1; }
[[ -d "$project/.git" ]] || { echo "$project is not a git repository"; exit 1; }

mkdir -p "$project/.github/workflows"
sed -e "s#__PIPELINE_REPO__#$pipeline_repo#g" -e "s#__PIPELINE_REF__#$ref#g" \
  "$here/templates/agent.yml" > "$project/.github/workflows/agent.yml"
echo "✓ wrote .github/workflows/agent.yml (pipeline: $pipeline_repo@$ref)"

if [[ -f "$project/.agent-pipeline.yml" ]]; then
  echo "• .agent-pipeline.yml already exists; left it alone"
else
  cp "$config_src" "$project/.agent-pipeline.yml"
  echo "✓ wrote .agent-pipeline.yml ($lang template) — edit the gates to match your project"
fi

if $configure_github; then
  command -v gh >/dev/null || { echo "gh CLI not found"; exit 1; }
  repo="$(cd "$project" && gh repo view --json nameWithOwner -q .nameWithOwner)"
  echo "Configuring $repo ..."
  gh label create "agent:build"       --repo "$repo" --color 0E8A16 --description "Builder agent implements this issue" --force
  gh label create "agent"             --repo "$repo" --color 5319E7 --description "Opened by the agent pipeline" --force
  gh label create "agent:needs-human" --repo "$repo" --color B60205 --description "Agent pipeline stopped; a human needs to take over" --force
  gh label create "agent:skip-review" --repo "$repo" --color CCCCCC --description "Don't run the reviewer agent on this PR" --force
  gh api -X PUT "repos/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=true >/dev/null
  echo "✓ labels created; Actions may now open PRs (workflow token stays read-only by default)"
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$repo" --body "$CLAUDE_CODE_OAUTH_TOKEN"
    echo "✓ CLAUDE_CODE_OAUTH_TOKEN secret set (runs use your Claude subscription)"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    gh secret set ANTHROPIC_API_KEY --repo "$repo" --body "$ANTHROPIC_API_KEY"
    echo "✓ ANTHROPIC_API_KEY secret set (runs are billed per token)"
  else
    echo "• No Claude credential in env. Set ONE of:"
    echo "    gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo $repo   # from 'claude setup-token' (subscription)"
    echo "    gh secret set ANTHROPIC_API_KEY --repo $repo         # API key (pay per token)"
  fi
fi

cat <<EOF

Next:
  1. Edit $project/.agent-pipeline.yml so the gates match how you lint/test this project.
  2. Commit and push both files to the default branch.
  3. Protect the default branch: require the "agent-review" status check and 1 human approval
     (see README "Branch protection").
  4. Label an issue "agent:build", or open a PR, and watch the Actions tab.
EOF
