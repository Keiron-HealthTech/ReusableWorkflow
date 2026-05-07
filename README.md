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
commenting `@codex` on the PR thread. The review uses a default
"good standards" prompt (correctness, security, error handling, tests,
readability, performance, API compatibility, configuration), which any caller
can override inline or via a file checked into the caller repo.

OpenAI Codex is the only supported backend. Azure-OpenAI passthrough is
intentionally out of scope.

#### Caller workflow

Drop the following file into the caller repo at
`.github/workflows/codex-review.yml`. It wires up both triggers in one place:
the `pull_request` job runs on every push that opens or updates a same-repo
PR, and the `issue_comment` job lets a maintainer re-trigger the review by
typing `@codex` on the PR thread.

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
    # fail. A maintainer can still review a fork PR by commenting `@codex`
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
    # Only run on `@codex` comments posted on PRs (not regular issues),
    # and only when the commenter is a repo OWNER, MEMBER, or COLLABORATOR.
    # This keeps the cost surface bounded — external CONTRIBUTORs cannot
    # burn credits, even on their own merged work.
    if: >-
      github.event_name == 'issue_comment' &&
      github.event.issue.pull_request != null &&
      contains(github.event.comment.body, '@codex') &&
      contains(fromJSON('["OWNER","MEMBER","COLLABORATOR"]'), github.event.comment.author_association)
    uses: Keiron-HealthTech/ReusableWorkflow/.github/workflows/codexPrReview.yml@main
    with:
      pr_number: ${{ github.event.pull_request.number || github.event.issue.number }}
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

A maintainer can still review a fork PR on demand by commenting `@codex` on
the PR thread. The `issue_comment` event runs in the **base** repository's
context with full secret access, so the review proceeds normally. The
trade-off: fully automated coverage for trusted same-repo work, gated manual
coverage for outside contributions.

#### Author-association retrigger gate

Only commenters whose `github.event.comment.author_association` is one of
`OWNER`, `MEMBER`, or `COLLABORATOR` can retrigger the review via `@codex`.
External `CONTRIBUTOR`s — even those with merged commits in the repo — are
deliberately blocked. Without this gate, anyone who can comment on a public
PR could spam `@codex` mentions and run up the OpenAI bill.

#### Customizing the prompt

The default prompt covers a "good standards" review (correctness, security,
error handling, tests, readability, performance, API compatibility,
configuration). Callers can override it in two mutually exclusive ways:

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

- **Adopt `@codex` only** (delete the `review-on-push` job) on repos where
  automatic review on every push would be excessive. Maintainers then
  request a review explicitly when they want one.
