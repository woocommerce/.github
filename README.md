# WooCommerce extension workflows

Plugin repositories keep the event triggers, required checks, and repository settings. The reusable workflows in [`.github/workflows/`](.github/workflows/) run CI, package candidates, and publish releases. The composites in [`actions/`](actions/) handle shared steps such as reading plugin configuration and verifying ZIPs.

## Caller contracts

| Plugin caller | Trigger | Shared workflow |
| --- | --- | --- |
| `ci.yml` | Pull request | `plugin-pr-ci.yml` |
| `ci-cron.yml` and `ci-cron-qit.yml` | Schedule or manual dispatch | `plugin-cron-ci.yml` and `plugin-cron-qit.yml` |
| `manual-ci.yml` | Manual dispatch | `plugin-test-runner.yml` |
| `release-start.yml` | Manual dispatch | `plugin-release-start.yml` |
| `ci-release-smoke-test.yml` | Release branch push | `plugin-release-smoke-test.yml` |
| `ci-release.yml` | Manual dispatch | `plugin-release.yml` |
| `request-external-review.yml` | Pull request target | `plugin-request-external-review.yml` |
| `test-the-build.yml` | Pull request, including drafts | `plugin-test-the-build.yml` |

`Required checks`, `Check changelog`, and `Validate @version Tag` are the plugin branch protection contexts. Keep their names stable. The aggregate PR check expects each applicable job to succeed and fails on drafts.

Set capabilities, versions, packaging options, and release product IDs in `package.json` under `config.woo`. The [configuration action](actions/read-plugin-config/action.yml) validates those settings with the WooCommerce reader and schema from one reviewed commit. The reader runs with Bash and jq before plugin dependency installation. Repository-specific setup belongs in the documented `bin/hooks/` scripts and package commands. These run in the checkout that supplies the candidate code.

PR CI reads configuration from the merge commit and version overrides from the PR head subject. A reusable job can accept the PR's configuration for that event commit. A job that checks out a different ref reads configuration from that ref. Pass artifact IDs, source SHAs, and checksums from build jobs to consumers so they verify the right ZIP.

Set `config.woo.zip.phpCompatibility.testVersion` to a PHP range such as `7.4-8.5` to scan the production ZIP with PHPCompatibilityWP before the build uploads it. The shared rules include bundled dependencies. Set `config.woo.zip.phpCompatibility.ignore` to a comma-separated list of PHPCS patterns for explicit exclusions, such as a dependency's version-guarded files. A plugin can supply `config.woo.zip.phpCompatibility.ruleset` to use its own PHPCS ruleset and locked `tools/php-quality` dependencies. Set the PHP range in that ruleset or in `testVersion`.

The preview workflow verifies the production ZIP and renders `tests/playground/comment.md` from the tested PR commit in the run summary. It also updates the PR comment on same-repository PRs, except Dependabot PRs. The template can use `$README_URL`, `$PLUGIN_SLUG`, `$PR_NUMBER`, and `$GITHUB_RUN_ID`. The GitHub download uses `$BUILD_URL` and `$BUILD_EXPIRES`.

Public repositories can pass `playground-files` to package the listed PHP fixtures alongside the ZIP. Put the browser blueprint in `tests/playground/blueprint-browser.json` with `__ARTIFACT_URL__` as the `unzip` step's `zipFile.url` and use `$PLAYGROUND_URL` in the comment. The proxy link includes the workflow name, so keep the caller named `Test the build`.

## Credentials and caches

External review runs on the base workflow and uses its explicit review credential. Fork PRs cannot use same-repository private-plugin coverage. Check which suites need a same-repo branch before merging. Release credentials belong in the steps that use them. Release jobs load their scripts from the pinned shared workflow revision. Candidate checkouts supply versions, change entries, and the tested ZIP. Both Marketplace submission and confirmation use the same product ID from the reviewed trunk config. Explicit release-candidate refs bypass dependency caches where the callers disable caching.

PRs restore pnpm, Composer, and Playwright caches. Eligible scheduled and trunk runs restore and save those same keys. Compare cache hits and runner time in the pilot when changing cache keys or writers.

QIT waits by default. Turn off `qit-wait` in Test Runner to queue managed checks, which the run summary marks as **submitted** after a successful enqueue. Activation, Woo API, Woo E2E, and API fuzz still report completed results.

## Updating the plugin callers

1. Review the shared diff and record its full commit SHA. Pin reusable workflows and actions to the reviewed SHA in the plugin callers.
2. Start with Bookings Availability. Exercise the required contexts, a PR with explicit test versions, and any scheduled or manual path the change touches.
3. Check repository-specific behavior in Accommodation Bookings, the Back in Stock Notifications Migrator, Coupon Campaigns, and Product Bundles. Then roll out to the remaining plugins.

See the plugin's `AGENTS.md` for release steps and local commands. [Start Release](.github/workflows/plugin-release-start.yml) prepares the branch and opens the release PR. [Publish release](.github/workflows/plugin-release.yml) uses the verified candidate. Use **Re-run failed jobs** for a publish retry once the candidate has been pinned.
