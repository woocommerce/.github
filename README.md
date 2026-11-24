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

During the move to central deployment, a plugin's `release-start.yml` and `ci-release.yml` call `plugin-release-start-central.yml` and `plugin-release-central.yml` instead. The central release workflow then holds the release credentials, so these callers forward no secrets except `ORG_DOWNLOADS` for E2E:

- Start Release (central deploy) bumps the versions and compiles the changelog on the dispatched trunk commit. Instead of pushing the branch, it uploads them as a `release-patch-<run attempt>` artifact (`release.patch` and `release.json`).
- Publish release (central deploy) requires an approved release PR. It names the build artifact `release-candidate-<commit>-<run attempt>` and the release job `Release (<commit> <SHA-256>)`, then stops after creating the GitHub release. It doesn't deploy, merge, roll the milestone or send Slack notifications.

The central workflows repeat the original jobs up to the GitHub release. Until the originals are removed, apply release workflow changes to both.

To enable Slack notifications, set `with.slack-channel` and forward `secrets.SLACK_WEBHOOK_URL` from the plugin caller. Leaving the channel blank disables delivery, including translation failure alerts. For a Slack app incoming webhook, supply a webhook URL already bound to the same channel. Legacy webhooks can use the channel supplied by the caller.

Set capabilities, versions, packaging options, and release product IDs in `package.json` under `config.woo`. The [configuration action](actions/read-plugin-config/action.yml) validates those settings with the WooCommerce reader and schema from one reviewed commit. The reader runs with Bash and jq before plugin dependency installation. Repository-specific setup belongs in the documented `bin/hooks/` scripts and package commands. These run in the checkout that supplies the candidate code.

PR CI reads configuration from the merge commit and version overrides from the PR head subject. A reusable job can accept the PR's configuration for that event commit. A job that checks out a different ref reads configuration from that ref. Pass artifact IDs, source SHAs, and checksums from build jobs to consumers so they verify the right ZIP.

Set `config.woo.zip.phpCompatibility.testVersion` to a PHP range such as `7.4-8.5` to scan the production ZIP with PHPCompatibilityWP before the build uploads it. The shared rules include bundled dependencies. Set `config.woo.zip.phpCompatibility.ignore` to a comma-separated list of PHPCS patterns for explicit exclusions, such as a dependency's version-guarded files. A plugin can supply `config.woo.zip.phpCompatibility.ruleset` to use its own PHPCS ruleset and locked `tools/php-quality` dependencies. Set the PHP range in that ruleset or in `testVersion`.

The preview workflow verifies the production ZIP and renders `tests/playground/comment.md` from the tested PR commit in the run summary. It also updates the PR comment on same-repository PRs, except Dependabot PRs. The template can use `$README_URL`, `$PLUGIN_SLUG`, `$PR_NUMBER`, and `$GITHUB_RUN_ID`. The GitHub download uses `$BUILD_URL` and `$BUILD_EXPIRES`.

Public repositories can pass `playground-files` to package the listed PHP fixtures alongside the ZIP. Put the browser blueprint in `tests/playground/blueprint-browser.json` with `__ARTIFACT_URL__` as the `unzip` step's `zipFile.url` and use `$PLAYGROUND_URL` in the comment. The proxy link includes the workflow name, so keep the caller named `Test the build`.

## Local changelog and version checks

The shared changelog and PHP `@version` scripts are also Composer binaries in `woocommerce/extension-checks`. Use the reviewed release commit SHA for the plugin's action pins and the exact version in its Composer manifest. The release assets provide a ZIP install for wp-env CLI containers and other environments without Git. For `v1.0.0`, use this configuration.

```json
{
    "repositories": [
        {
            "type": "composer",
            "url": "https://github.com/woocommerce/.github/releases/download/v1.0.0",
            "only": ["woocommerce/extension-checks"]
        }
    ],
    "require-dev": {
        "woocommerce/extension-checks": "1.0.0"
    }
}
```

Commit `composer.lock` and verify that both the source and ZIP references match the validator action pins. After `composer install`, both commands run offline.

- Run `vendor/bin/check_changelog.sh` from the plugin root. It uses the plugin's `package.json` to identify the root and the plugin's `automattic/jetpack-changelogger` development dependency to validate changes.
- Run `vendor/bin/version_updated.sh <file>...` with the changed PHP files, as lint-staged does. This also works in Composer-only jobs. The local command skips the version check on `trunk`.

### Publishing an update

Tag the reviewed merge commit and create the GitHub release. From this repository, build the ZIP and Composer index for that tag, then attach both files to the release. Keep the index and ZIP on the same tag. Publish a new tag whenever the assets change.

```bash
tag=v1.0.0
version=${tag#v}
ref=$(git rev-parse "$tag^{commit}")
zip="extension-checks-$version.zip"
base="https://github.com/woocommerce/.github/releases/download/$tag"

git archive --format=zip --prefix="extension-checks-$version/" --output="$zip" "$ref"
checksum=$(shasum -a 1 "$zip" | cut -d ' ' -f 1)
git show "$ref:composer.json" | jq --arg version "$version" --arg ref "$ref" \
    --arg url "$base/$zip" --arg checksum "$checksum" '
    . + {
        version: $version,
        source: {type: "git", url: "https://github.com/woocommerce/.github.git", reference: $ref},
        dist: {type: "zip", url: $url, reference: $ref, shasum: $checksum}
    } | {packages: {(.name): {($version): .}}}
' > packages.json
gh release upload "$tag" "$zip" packages.json --repo woocommerce/.github
```

Before updating callers, run `composer update woocommerce/extension-checks` against the new repository URL and test a clean `composer install --prefer-dist` without Git. Verify that both installed scripts match the release commit.

## Credentials and caches

External review runs on the base workflow and uses its explicit review credential. Fork PRs cannot use same-repository private-plugin coverage. Check which suites need a same-repo branch before merging. Release credentials belong in the steps that use them. Release jobs load their scripts from the pinned shared workflow revision. Candidate checkouts supply versions, change entries, and the tested ZIP. Both Marketplace submission and confirmation use the same product ID from the reviewed trunk config. Explicit release-candidate refs bypass dependency caches where the callers disable caching.

PRs restore pnpm, Composer, and Playwright caches. Eligible scheduled and trunk runs restore and save those same keys. Compare cache hits and runner time in the pilot when changing cache keys or writers.

QIT waits by default. Turn off `qit-wait` in Test Runner to queue managed checks, which the run summary marks as **submitted** after a successful enqueue. Activation, Woo API, Woo E2E, and API fuzz still report completed results.

## Updating the plugin callers

1. Review the shared diff and record its full commit SHA. Pin reusable workflows and actions to the reviewed SHA in the plugin callers.
2. Start with Bookings Availability. Exercise the required contexts, a PR with explicit test versions, and any scheduled or manual path the change touches.
3. Check repository-specific behavior in Accommodation Bookings, the Back in Stock Notifications Migrator, Coupon Campaigns, and Product Bundles. Then roll out to the remaining plugins.

See the plugin's `AGENTS.md` for release steps and local commands. [Start Release](.github/workflows/plugin-release-start.yml) prepares the branch and opens the release PR. [Publish release](.github/workflows/plugin-release.yml) uses the verified candidate. Use **Re-run failed jobs** for a publish retry once the candidate has been pinned.
