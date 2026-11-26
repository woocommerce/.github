#!/usr/bin/env bash

set -euo pipefail

tools=$1
export CONFIG_READER=$2

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd -P "$fixture"
fixture=$PWD

expect_failure() {
    local message=$1 output
    shift
    if output=$("$@" 2>&1) || [[ "$output" != *"$message"* ]]; then
        printf 'Expected failure mentioning %s:\n%s\n' "$message" "$output" >&2
        exit 1
    fi
}

# This candidate predates shared tools and carries a different Marketplace ID.
mkdir -p candidate/includes mock-bin
cd candidate
cat > package.json <<'JSON'
{
    "name": "example-extension",
    "version": "1.2.3",
    "config": {
        "wp_org_slug": "example-extension",
        "woo": {
            "versionPatterns": [{"file": "includes/version.php", "pattern": "const VERSION = '%s';"}],
            "release": {"productId": 999, "wpOrgSlug": "example-extension", "readmeChangelog": true}
        }
    }
}
JSON
printf '<?php\n/**\n * Version: 1.2.3\n * WC tested up to: 11.2\n */\n' > example-extension.php
printf "<?php\nconst VERSION = '1.2.3';\n/** @version x.x.x */\n" > includes/version.php
printf 'Stable tag: 1.2.3\nTested up to: 6.9\nWC tested up to: 11.2\n\n== Changelog ==\n\n= 1.2.3 - 2026-11-15 =\n* Fix - Earlier release.\n' > readme.txt
printf '= 1.2.4 - 2026-11-17 =\n* Fix - Release contents.\n\n= 1.2.3 - 2026-11-15 =\n* Fix - Earlier release.\n' > changelog.txt
git init --quiet --initial-branch=trunk
git add package.json readme.txt example-extension.php includes/version.php changelog.txt

export RELEASE_VERSION=1.2.4
bash "$tools/update_version.sh" "$RELEASE_VERSION" --wp 7.0 --wc 11.3
grep -qFx 'Tested up to: 7.0' readme.txt
grep -qFx ' * WC tested up to: 11.3' example-extension.php
grep -qFx '/** @version 1.2.4 */' includes/version.php
expect_failure 'No readme.txt changelog entry' bash "$tools/check_versions.sh"
bash "$tools/sync_readme_changelog.sh" "$RELEASE_VERSION"
bash "$tools/sync_readme_changelog.sh" "$RELEASE_VERSION"
[[ $(grep -cFx '= 1.2.4 - 2026-11-17 =' readme.txt) == 1 ]]
bash "$tools/check_versions.sh"
expect_failure 'does not match' env RELEASE_VERSION=1.2.5 bash "$tools/check_versions.sh"
cp changelog.txt "$fixture/changelog.txt"
printf '= 1.2.4 - invalid =\n* Fix - Release contents.\n' > changelog.txt
expect_failure 'Invalid date format found in changelog' bash "$tools/check_versions.sh"
cp "$fixture/changelog.txt" changelog.txt

# The archive name comes from the verified build, independent of the checkout name.
export RELEASE_ARCHIVE=example-extension.zip
mkdir example-extension
cp example-extension.php example-extension/
zip -q -r "$RELEASE_ARCHIVE" example-extension
archive_hash=$(sha256sum "$RELEASE_ARCHIVE")
export RELEASE_SHA256=${archive_hash%% *}
export GITHUB_OUTPUT="$fixture/github-output"
export GITHUB_REPOSITORY=woocommerce/example-extension
export GH_RELEASE_COMMIT=1234567890123456789012345678901234567890
export RELEASE_LOG="$fixture/release-log"

cat > "$fixture/mock-bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -eu
case "$*" in
    'auth status')
        ;;
    "api repos/$GITHUB_REPOSITORY/git/matching-refs/tags/$RELEASE_VERSION")
        if [[ ${TAG_MISSING:-false} == true ]]; then
            printf '%s\n' '[]'
        else
            jq -cn --arg version "$RELEASE_VERSION" '[{ref: ("refs/tags/" + $version)}]'
        fi
        ;;
    "api -X POST repos/$GITHUB_REPOSITORY/git/refs -f ref=refs/tags/$RELEASE_VERSION -f sha=$GH_RELEASE_COMMIT")
        printf '%s\n' tag-created >> "$RELEASE_LOG"
        ;;
    "api repos/$GITHUB_REPOSITORY/commits/refs%2Ftags%2F$RELEASE_VERSION --jq .sha")
        printf '%s\n' "${TAG_COMMIT:-$GH_RELEASE_COMMIT}"
        ;;
    "release view $RELEASE_VERSION --json assets,isDraft")
        [[ -n ${EXISTING_DIGEST:-} ]] || exit 1
        jq -cn --arg name "$RELEASE_ARCHIVE" --arg digest "$EXISTING_DIGEST" \
            --argjson draft "${EXISTING_DRAFT:-false}" '{assets: [{name: $name, digest: $digest}], isDraft: $draft}'
        ;;
    "release edit $RELEASE_VERSION --draft=false")
        printf '%s\n' published >> "$RELEASE_LOG"
        ;;
    "release create $RELEASE_VERSION $RELEASE_ARCHIVE "*)
        [[ $* == *'Fix - Release contents.'* && $* == *'--verify-tag' ]]
        printf '%s\n' created >> "$RELEASE_LOG"
        ;;
    *)
        printf 'Unexpected GitHub call: %s\n' "$*" >&2
        exit 2
        ;;
esac
MOCK

cat > "$fixture/mock-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
case "${!#}" in
    'https://woocommerce.com/wp-json/helper/1.0/info')
        [[ " $* " == *" --data-urlencode product_id=$PRODUCT_ID "* ]]
        version=${PUBLISHED_VERSION:-1.2.3}
        if [[ -n ${CONFIRM_POLLS:-} ]]; then
            printf '%s\n' poll >> "$CONFIRM_POLLS"
            if [[ $(wc -l < "$CONFIRM_POLLS") -eq ${PUBLISH_ON_POLL:-0} ]]; then
                version=$RELEASE_VERSION
            fi
        fi
        jq -cn --arg version "$version" '{version: $version}'
        ;;
    'https://woocommerce.com/wp-json/wc/submission/runner/v1/product/deploy/status')
        [[ " $* " == *" --form-string product_id=$PRODUCT_ID "* ]]
        if [[ ${MARKETPLACE_ACTIVE:-false} == true ]]; then
            jq -cn --arg version "$RELEASE_VERSION" '{version: $version, status: "active"}'
        else
            printf '%s\n' '{"code":"submission_runner_no_deploy_in_progress"}'
            exit 22
        fi
        ;;
    'https://woocommerce.com/wp-json/wc/submission/runner/v1/product/deploy')
        [[ " $* " == *" --form-string product_id=$PRODUCT_ID "* ]]
        [[ " $* " == *" -F file=@./$RELEASE_ARCHIVE "* ]]
        printf '%s\n' uploaded >> "$RELEASE_LOG"
        printf '%s\n' '{"success":true}'
        ;;
    'https://api.wordpress.org/plugins/info/1.2/')
        jq -cn --arg version "$RELEASE_VERSION" '{version: $version}'
        ;;
    "https://translate.wordpress.com/api/import-new-release/woocommerce/example-extension/$RELEASE_VERSION")
        if [[ ${TRANSLATION_ERROR:-false} == true ]]; then
            printf '%s\n' '{"success":false,"message":"Bad \"payload\""}'
        else
            printf '%s\n' '{"success":true}'
        fi
        ;;
    'https://example.invalid/slack')
        printf '%s\n' slack-requested >> "$RELEASE_LOG"
        while [[ "$1" != --data ]]; do shift; done
        jq -e '.channel == "#team-releases" and (.text | contains("Bad \\\"payload\\\""))' <<< "$2" > /dev/null
        printf '%s\n' notified >> "$RELEASE_LOG"
        ;;
    *)
        printf 'Unexpected HTTP call: %s\n' "${!#}" >&2
        exit 2
        ;;
esac
MOCK
chmod +x "$fixture/mock-bin/gh" "$fixture/mock-bin/curl"
export PATH="$fixture/mock-bin:$PATH"

TAG_MISSING=true bash "$tools/release.sh"
test "$(cat "$RELEASE_LOG")" = $'tag-created\ncreated'
EXISTING_DIGEST="sha256:$RELEASE_SHA256" bash "$tools/release.sh"
test "$(cat "$RELEASE_LOG")" = $'tag-created\ncreated'
EXISTING_DIGEST="sha256:$RELEASE_SHA256" EXISTING_DRAFT=true bash "$tools/release.sh"
test "$(tail -1 "$RELEASE_LOG")" = published
expect_failure 'points to' env TAG_COMMIT=other bash "$tools/release.sh"
expect_failure 'existing release ZIP differs' env EXISTING_DIGEST=sha256:other bash "$tools/release.sh"

export PRODUCT_ID=123
export DEPLOY_API_KEY=fixture-user DEPLOY_API_SECRET=fixture-password
: > "$GITHUB_OUTPUT"
bash "$tools/deploy.sh" prepare
grep -qFx 'upload=true' "$GITHUB_OUTPUT"
bash "$tools/deploy.sh" submit
[[ $(grep -cFx uploaded "$RELEASE_LOG") == 1 ]]
: > "$GITHUB_OUTPUT"
MARKETPLACE_ACTIVE=true UPLOAD_PREVIOUSLY_ATTEMPTED=true bash "$tools/deploy.sh" prepare
test ! -s "$GITHUB_OUTPUT"
expect_failure 'earlier attempt' env UPLOAD_PREVIOUSLY_ATTEMPTED=true bash "$tools/deploy.sh" prepare
expect_failure 'checksum does not match' env RELEASE_SHA256="$(printf '%064d' 0)" bash "$tools/deploy.sh" submit
test "$(grep -cFx uploaded "$RELEASE_LOG")" = 1
PUBLISHED_VERSION="$RELEASE_VERSION" bash "$tools/deploy.sh" confirm

# Simulate the five-minute polling intervals without waiting for the Marketplace.
cat > "$fixture/advance-clock" <<'MOCK'
sleep() {
    [[ "$1" == 300 ]] || return 1
    SECONDS=$((SECONDS + $1))
}
MOCK
CONFIRM_POLLS="$fixture/polls" PUBLISH_ON_POLL=17 BASH_ENV="$fixture/advance-clock" bash "$tools/deploy.sh" confirm
[[ $(wc -l < "$fixture/polls") -eq 17 ]]
: > "$fixture/polls"
expect_failure 'has not confirmed' env CONFIRM_POLLS="$fixture/polls" BASH_ENV="$fixture/advance-clock" \
    bash "$tools/deploy.sh" confirm
[[ $(wc -l < "$fixture/polls") -eq 17 ]]

# A real local SVN tag exercises retry verification without any deploy credentials.
export WPORG_SVN_URL="file://$fixture/svn"
export WP_ORG_SLUG=example-extension
svnadmin create "$fixture/svn"
svn mkdir -q --parents "$WPORG_SVN_URL/$WP_ORG_SLUG/tags" -m 'Initialize fixture'
: > "$GITHUB_OUTPUT"
bash "$tools/wporg-deploy.sh" prepare
grep -qFx 'deploy=true' "$GITHUB_OUTPUT"
tag="$WPORG_SVN_URL/$WP_ORG_SLUG/tags/$RELEASE_VERSION"
svn import -q example-extension "$tag" -m 'Release fixture'
: > "$GITHUB_OUTPUT"
bash "$tools/wporg-deploy.sh" prepare
grep -qFx 'deploy=false' "$GITHUB_OUTPUT"
expect_failure 'must match' env WP_ORG_SLUG=other-extension bash "$tools/wporg-deploy.sh" prepare
expect_failure 'checksum does not match' env RELEASE_SHA256="$(printf '%064d' 0)" bash "$tools/wporg-deploy.sh" prepare
svn delete -q "$tag/example-extension.php" -m 'Change fixture tag contents'
expect_failure 'differs from the released archive' bash "$tools/wporg-deploy.sh" prepare
bash "$tools/wporg-deploy.sh" confirm

PLUGIN_SLUG=example-extension bash "$tools/update_translations.sh"
for channel in '' '   '; do
    expect_failure 'An error occurred' env PLUGIN_SLUG=example-extension TRANSLATION_ERROR=true \
        SLACK_WEBHOOK_URL=https://example.invalid/slack SLACK_CHANNEL="$channel" bash "$tools/update_translations.sh"
done
if grep -qFx slack-requested "$RELEASE_LOG"; then
    echo 'The translation alert was sent without a channel.' >&2
    exit 1
fi
expect_failure 'An error occurred' env PLUGIN_SLUG=example-extension TRANSLATION_ERROR=true \
    SLACK_WEBHOOK_URL=https://example.invalid/slack SLACK_CHANNEL=' #team-releases ' bash "$tools/update_translations.sh"
test "$(tail -1 "$RELEASE_LOG")" = notified
