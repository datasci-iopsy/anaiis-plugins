# Track B: GitHub Actions Label Trigger

This is a reference only. The pr-af skill never installs this workflow into any repo on
its own; wiring it in is a separate, explicit, per-repo ask (visible CI change, needs a
repo secret). Track A (the local `af` CLI, what `SKILL.md` actually drives) is the
default; this document exists so adopting Track B later is copy-paste plus one secret,
not a research project.

## Cost model (read this before enabling)

LLM spend is identical to Track A: same OpenRouter key, same pr-af engine, same
per-review cost ceiling (`PR_AF_MAX_COST_USD`). Track B's actual delta is GitHub Actions
**runner minutes** (free on public repos, metered on private repos) plus machine
independence (the review runs even if your laptop is off). Do not conflate "this costs
more" with "this uses more LLM tokens" when deciding whether to enable it.

## Upstream workflow (verbatim, from the pr-af README)

Zero-config: triggers automatically when the `pr-af` label is added to a PR, uses
GitHub's built-in `GITHUB_TOKEN`.

```yaml
name: AgentField PR Review

on:
  pull_request:
    types: [labeled]

jobs:
  pr-af-review:
    if: github.event.label.name == 'pr-af'
    runs-on: ubuntu-latest

    # Needs permissions to post comments and read code
    permissions:
      contents: read
      pull-requests: write

    steps:
      - name: Checkout PR-AF
        uses: actions/checkout@v4
        with:
          repository: Agent-Field/pr-af
          # Pinned to a reviewed full commit SHA (Agent-Field/pr-af main HEAD,
          # reviewed 2026-09-05). Update only after explicitly reviewing the new
          # revision; never point it at a moving ref.
          ref: 48ae7eeb4f07779004db6354728d49ca7b36dbc3
          path: pr-af

      - name: Start AgentField & PR-AF
        working-directory: ./pr-af
        env:
          OPENROUTER_API_KEY: ${{ secrets.OPENROUTER_API_KEY }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          # --wait gates on pr-af's healthcheck (Compose v2.20+); the agentfield
          # service defines none, so probe its API directly below.
          docker compose up -d --wait
          for i in $(seq 1 30); do
            curl -fsS http://localhost:8080/api/v1/reasoners >/dev/null && break
            sleep 2
          done
          curl -fsS http://localhost:8080/api/v1/reasoners >/dev/null || {
            echo "AgentField API did not become ready" >&2
            exit 1
          }

      - name: Execute Deep Architectural Audit
        working-directory: ./pr-af
        env:
          PR_URL: ${{ github.event.pull_request.html_url }}
        run: |
          python3 scripts/ci_runner.py
```

Note: PR-AF runs a comprehensive parallel pipeline. Reviews typically take 35-50 minutes
depending on PR complexity.

## Per-repo checklist (ask-first, each step)

1. Add the workflow file above at `.github/workflows/pr-af-review.yml` in the target
   repo.
2. Add `OPENROUTER_API_KEY` as a repository secret (Settings, Secrets and variables,
   Actions). `GH_TOKEN` needs no separate secret; the built-in `GITHUB_TOKEN` covers it.
3. Create (or confirm the existence of) a `pr-af` label in the repo, since the workflow's
   trigger condition is `github.event.label.name == 'pr-af'`.
4. To run a review: add the `pr-af` label to an open PR. To re-run after new commits,
   remove and re-add the label (each labeling is a fresh, paid run; there is no
   Track-B-side idempotency check the way Track A's `run-af-review.sh` has, since the
   run key / archive-skip logic is a Track A concept only).

## What Track B does NOT give you

- No cross-referencing against CodeRabbit threads, no guarded reply posting, no
  `xref.sh`/`reply-cr.sh` equivalent. The engine posts its own inline comments only, per
  its own token's write access, exactly as documented in the main README's "One-Call DX"
  section. Track B is the bare engine, not this skill's Phase 2-4 behavior.
- No local verbatim archive (`response.json`, `meta.json`, `timing.json`) the way
  `run-af-review.sh` produces under `~/.pr-af/runs/`. Whatever the engine posts to the PR
  is the only durable record unless you separately capture the workflow's logs.

If cross-referencing and guarded replies are wanted on a CI-triggered run, that is future
scope, not something this reference doc or the current skill implements.
