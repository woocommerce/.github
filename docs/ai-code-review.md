# AI Code Review

Reusable workflow at `.github/workflows/ai-code-review.yml`. Posts AI-generated review comments on PRs in opted-in `woocommerce` and `mailpoet` org repos.

## Caller setup

Add a workflow file at `.github/workflows/ai-code-review.yml` in the consuming repo:

```yaml
name: AI Code Review
on:
  pull_request:
    types: [opened, ready_for_review, reopened]
  issue_comment:
    types: [created]

concurrency:
  group: ai-review-${{ github.event.pull_request.number || github.event.issue.number }}-${{ github.event_name }}
  cancel-in-progress: true

jobs:
  review:
    uses: woocommerce/.github/.github/workflows/ai-code-review.yml@trunk
    secrets:
      AI_CODE_REVIEW_ANTHROPIC_API_KEY: ${{ secrets.AI_CODE_REVIEW_ANTHROPIC_API_KEY }}
```

Set `AI_CODE_REVIEW_ANTHROPIC_API_KEY` as a repo or org secret.

## Triggers

| Event | When it fires |
|---|---|
| PR opened | Auto first review (skips drafts and forks) |
| PR ready for review (draft to ready) | Auto review |
| PR reopened | Auto review |
| Push to PR | No re-review (synchronize is filtered) |
| Comment `@claude review` or `@claude /review` | Re-review on demand |

Comment trigger requires the comment author to have admin or write on the repo. Closed and merged PRs do not re-trigger.

## Collision with `claude-code-action` in tag mode

The Anthropic Claude GitHub App can be configured separately to respond to `@claude` mentions in PR comments (tag mode). If your repo has both this AI review workflow AND a tag-mode workflow, comments containing `@claude review` or `@claude /review` will fire BOTH workflows and the user will get two responses.

If your repo uses tag mode, either:

1. Restrict the tag-mode workflow's `if:` to specific senders (e.g., a service account) so human-typed `@claude review` does not fire it. Reference: `Automattic/wp-calypso`'s `claude.yml` restricts tag mode to `matticbot`.
2. Or disable tag mode on this repo and use the AI Code Review workflow as the single Claude integration.

## References

- Reusable workflow: `.github/workflows/ai-code-review.yml`
- Spec: `docs/superpowers/specs/2026-05-06-ai-review-comment-command-trigger-design.md`
- Linear: QAO-430 (re-trigger via comment), QAO-429 (synchronize skip)
