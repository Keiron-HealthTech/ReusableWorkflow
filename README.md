<p align="center">
  <img src="https://avatars0.githubusercontent.com/u/44036562?s=100&v=4"/> 
</p>

## Templates repository

In this repository are the actions for the deployment

#### Utils:

- [Github Action Docs](https://docs.github.com/es/actions)

#### Example (buildKanikoAndChangeImage):

```
name: NAME
on:
  workflow_dispatch:
  push:
    branches:
      - "develop"
jobs:
  deployment:
    uses: Keiron-HealthTech/ReusableWorkflow/.github/workflows/buildKanikoAndChangeImage.yml@main
    with:
      namespace: NAMESPACES
      app_name: APPNAME
      image_repository_name: NAME_ECR
      cluster_name: EKS_NAME
      environment: ENVIRONMENT
      runner: RUNNER
    secrets:
      aws_account_id: ${{ secrets.AWS_ACCOUNT_ID }}
      personal_token: ${{ secrets.PERSONAL_TOKEN }}
```

#### Example (buildImageAndPublishECR):

```
name: NAME
on:
  workflow_dispatch:
  push:
    branches:
      - "develop"
jobs:
  deployment:
    uses: Keiron-HealthTech/ReusableWorkflow/.github/workflows/buildImageAndPublishECR.yml@main
    with:
      namespace: NAMESPACES
      app_name: APPNAME
      image_repository_name: NAME_ECR
      cluster_name: EKS_NAME
      environment: ENVIRONMENT
      runner: RUNNER
    secrets:
      aws_account_id: ${{ secrets.AWS_ACCOUNT_ID }}
      personal_token: ${{ secrets.PERSONAL_TOKEN }}
```

## Codex PR Review

Reusable workflow that runs an automated [OpenAI Codex](https://openai.com/index/introducing-codex/)
review on a pull request and posts the verdict as a single PR comment. It is
designed for dual-trigger adoption: the same workflow runs automatically when
a PR is opened or updated, and can be re-triggered on demand by maintainers
commenting `/codex-review` on the PR thread. The review uses a default
verified-findings-only prompt, which any caller can override inline or via a
file checked into the caller repo.

OpenAI Codex is the only supported backend. Azure-OpenAI passthrough is
intentionally out of scope.

#### Caller workflow

Drop the following file into the caller repo at
`.github/workflows/codex-review.yml`. It wires up both triggers in one place:
the `pull_request` job runs on every push that opens or updates a same-repo
PR, and the `issue_comment` job lets a maintainer re-trigger the review by
typing `/codex-review` on the PR thread.

```yaml
name: Codex PR Review

on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

jobs:
  review-on-push:
    # Skip PRs from forks: GitHub omits secrets on `pull_request` events
    # raised from forks, so the OpenAI key would be empty and the run would
    # fail. A maintainer can still review a fork PR by commenting `/codex-review`
    # (see `review-on-comment` below), which runs in the base-repo context
    # with full secret access.
    if: >-
      github.event_name == 'pull_request' &&
      github.event.pull_request.head.repo.full_name == github.repository
    uses: Keiron-HealthTech/ReusableWorkflow/.github/workflows/codexPrReview.yml@main
    with:
      pr_number: ${{ github.event.pull_request.number }}
    secrets:
      openai_api_key: ${{ secrets.OPENAI_API_KEY }}

  review-on-comment:
    # Only run on `/codex-review` comments posted on PRs (not regular issues),
    # and only when the commenter is a repo OWNER, MEMBER, or COLLABORATOR.
    # This keeps the cost surface bounded — external CONTRIBUTORs cannot
    # burn credits, even on their own merged work.
    #
    # `allowed_base_branches` mirrors the `branches:` filter on the
    # pull_request trigger above. The issue_comment event is not
    # branch-scoped at the trigger level, so the reusable workflow
    # enforces the filter from this input. Drop it (or leave it empty)
    # if you want maintainers to be able to retrigger on any base branch.
    if: >-
      github.event_name == 'issue_comment' &&
      github.event.issue.pull_request != null &&
      contains(github.event.comment.body, '/codex-review') &&
      contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)
    uses: Keiron-HealthTech/ReusableWorkflow/.github/workflows/codexPrReview.yml@main
    with:
      pr_number: ${{ github.event.pull_request.number || github.event.issue.number }}
      allowed_base_branches: "development"
    secrets:
      openai_api_key: ${{ secrets.OPENAI_API_KEY }}
```

Pin `@main` to a tag (e.g., `@v1.0.0`) once you've cut a release in this
repo; pinning by commit SHA is also supported.

#### Permissions

The reusable workflow declares the permissions it needs (`contents: read`,
`pull-requests: write`, `issues: write`). The caller's `GITHUB_TOKEN` must
not be more restrictive than these — if your caller workflow declares its
own top-level `permissions:` block, ensure it includes at least:

```yaml
permissions:
  contents: read
  pull-requests: write
  issues: write
```

If the caller omits a top-level `permissions:` block entirely, the repo's
default token permissions apply, which is usually sufficient for
Keiron-HealthTech repos.

#### Fork-PR behavior

External contributors' PRs from forked repositories will **not** trigger the
automatic `pull_request` review: GitHub deliberately withholds repository
secrets (including `OPENAI_API_KEY`) on fork-originated `pull_request`
events to prevent secret exfiltration. The `if:` guard
`github.event.pull_request.head.repo.full_name == github.repository`
short-circuits those runs cleanly so the workflow does not fail spuriously.

The reusable workflow also enforces this guard internally via the
`allow_fork_prs` input (default `false`). When the resolved PR head is
from a fork and the caller has not opted in, the workflow posts a
one-line skip comment and exits cleanly — secrets are never passed to
`actions/checkout` or `openai/codex-action`. This second layer matters
for the `issue_comment` retrigger path: an `issue_comment` event runs in
the **base** repository's context with full secret access, and the
event payload does not carry `head.repo` metadata, so the caller-level
`if:` filter that protects the `pull_request` path is not available
there. To intentionally review a fork PR (manual maintainer trigger),
pass `allow_fork_prs: true`:

```yaml
with:
  pr_number: ${{ github.event.pull_request.number || github.event.issue.number }}
  allow_fork_prs: true
```

#### Base-branch allowlist

The reusable workflow accepts an optional `allowed_base_branches` input
(comma-separated string, empty default = any base accepted). When
non-empty, the review runs only if the PR's base branch is in the list.
This is the issue_comment-path equivalent of the `branches:` filter on
the `pull_request` trigger — `issue_comment` events fire regardless of
base branch, and there is no native trigger-level filter for them, so
the reusable workflow enforces the allowlist after resolving PR
metadata via `gh pr view`.

```yaml
with:
  pr_number: ${{ github.event.pull_request.number || github.event.issue.number }}
  allowed_base_branches: "development,release"
```

When the guard trips, the workflow posts a one-line skip comment naming
the offending base branch and exits cleanly — Codex is never invoked.

#### Author-association retrigger gate

Only commenters whose `github.event.comment.author_association` is one of
`OWNER`, `MEMBER`, or `COLLABORATOR` can retrigger the review via `/codex-review`.
External `CONTRIBUTOR`s — even those with merged commits in the repo — are
deliberately blocked. Without this gate, anyone who can comment on a public
PR could spam `/codex-review` comments and run up the OpenAI bill.

The phrase is `/codex-review`, not `@codex`. `@codex` is the mention the
ChatGPT Codex GitHub app listens for: it answers every `@codex` with a
"create a Codex account" comment. That extra
comment cancels the in-flight review through the caller's concurrency group,
and a caller gate matching `codex` in commenter logins then reads it as
"already reviewed".

#### Re-runs, prior context, and outdated reviews

- Each review comment carries a `<!-- codex-review sha=<head> -->` marker.
  Automatic runs skip a head SHA that already has a review, so CI re-runs
  don't produce duplicate reviews. `/codex-review` always runs.
- The prompt includes the PR title and description, the previous Codex
  review, and the last 15 human comments. Codex uses them to avoid
  re-raising findings a human already dismissed.
- After posting, older Codex reviews are collapsed as "outdated", so the PR
  shows one current review.
- Runs that produce no usable review (empty output, or Codex could not read
  the repo) post nothing. See the workflow run log.
- The Codex step passes `project_doc_fallback_filenames=["CLAUDE.md"]`. Codex
  resolves this per directory and takes the first match, `AGENTS.md` first:
  `CLAUDE.md` is loaded only in directories with no `AGENTS.md`. If both
  exist (or an `AGENTS.md` is added later), `CLAUDE.md` is silently ignored there.

#### Inline comments

Set `inline_comments: true` to get each finding as an inline review comment
on its diff line, instead of only a single PR comment:

```yaml
with:
  pr_number: ${{ github.event.pull_request.number }}
  prompt_file: .github/codex/pr-review.prompt.md
  inline_comments: true
```

- Codex answers in JSON with the schema at
  `.github/codex/review-output.schema.json` (verdict, summary, findings with
  `path`/`line`/`severity`, notes). The workflow appends the output format to
  the end of the prompt, so the caller prompt keeps its criteria and
  severities unchanged and its own output format section is overridden.
- The PR comment keeps the verdict, the summary, findings whose line is not
  in the diff, and the notes. It carries the usual `codex-review sha=` marker,
  so re-runs, prior context and outdated collapsing work the same way.
- Findings on a diff line are posted as one review with `event: COMMENT`. It
  never approves or requests changes. Inline comments from older runs are
  collapsed as outdated.
- Default `false`: callers that don't set it keep the single-comment output.

#### Customizing the prompt

The default prompt asks for verified findings only (bugs, security, breaking
changes, error handling), at most five, in a compact format. A clean PR gets
a two-line approval. Callers can override it in two mutually exclusive ways:

1. **Inline `review_prompt` input** — paste a multiline string directly in
   the caller workflow:

   ```yaml
   with:
     pr_number: ${{ github.event.pull_request.number }}
     review_prompt: |
       Focus exclusively on database migration safety. Flag any
       irreversible schema change without a backfill plan.
   ```

2. **`prompt_file` input** — point at a Markdown file checked into the
   caller repo. The reusable workflow reads it from the caller's checkout:

   ```yaml
   with:
     pr_number: ${{ github.event.pull_request.number }}
     prompt_file: .github/codex/my-custom-prompt.md
   ```

If neither input is set, the workflow uses the default prompt bundled in
this repo at `.github/codex/pr-review.prompt.md`. If both are set, the
inline `review_prompt` wins. If `prompt_file` points at a path that does
not exist in the caller's checkout, the workflow fails fast with a clear
error message naming the missing path — so a typo cannot silently fall
back to the default.

#### Cost-control patterns

- **Filter by `paths:`** on noisy mono-repos so trivial doc-only PRs do
  not burn an OpenAI run:

  ```yaml
  on:
    pull_request:
      types: [opened, synchronize, reopened]
      paths:
        - "src/**"
        - "lib/**"
        - "!**/*.md"
  ```

- **Adopt `/codex-review` only** (delete the `review-on-push` job) on repos where
  automatic review on every push would be excessive. Maintainers then
  request a review explicitly when they want one.
