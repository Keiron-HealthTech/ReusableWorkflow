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
    uses: keiron-git/ReusableWorkflow/.github/workflows/buildKanikoAndChangeImage.yml@main
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
    uses: keiron-git/ReusableWorkflow/.github/workflows/buildImageAndPublishECR.yml@main
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
