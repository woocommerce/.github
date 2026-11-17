#!/usr/bin/env bash

set -euo pipefail

actions=$(cd "$(dirname "$0")/../actions" && pwd)
parser="$actions/read-pr-versions/parse-commit-message-args.js"
version_check="$actions/check-version/version_updated.sh"
changelog_check="$actions/check-changelog/check_changelog.sh"

expect_failure() {
    local output
    if output=$("$@" 2>&1); then
        printf '%s\n' "$output"
        echo "Expected failure: $*" >&2
        exit 1
    fi
}

subject='Check versions --test-wc-version=9.7.0-rc.1 --test-wp-version=nightly --test-php-version=8.4 --test-php-version=8.5'
[[ $(node "$parser" "$subject" wc-version __default__) == '9.7.0-rc.1' ]]
[[ $(node "$parser" "$subject" wp-version __default__) == 'nightly' ]]
[[ $(node "$parser" "$subject" php-version __default__) == '8.4' ]]
[[ $(node "$parser" 'No override' wc-version __default__) == '__default__' ]]
expect_failure node "$parser" "$subject"

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cd -P "$fixture"
git init --quiet --initial-branch=trunk
git -c user.name=Test -c user.email=test@example.test commit --quiet --allow-empty -m Base
git update-ref refs/remotes/origin/trunk HEAD
git switch --quiet --create change

printf '<?php\n/** @version x.x.x */\nfinal class Updated {}\n' > 'Updated class.php'
printf '<?php\nenum Missing {}\n' > 'Missing version.php'
GITHUB_ACTIONS=false bash "$version_check" 'Updated class.php'
expect_failure env GITHUB_ACTIONS=false bash "$version_check" 'Missing version.php'

mkdir -p changelog vendor/bin
printf '{}\n' > package.json
export GITHUB_ENV="$fixture/github-env"
export GITHUB_REF_NAME='1/merge'
export GITHUB_BASE_REF=trunk
expect_failure env GITHUB_ACTIONS=true bash "$version_check" 'Missing version.php'
grep -qFx 'FAILED_FILES=Missing version.php ' "$GITHUB_ENV"

# Verify the wrapper invokes Changelogger on each selected file.
cat > vendor/bin/changelogger <<'PHP'
<?php
$expected = array( 'validate', '--gh-action', '--basedir=' . getcwd(), 'changelog/entry' );
exit( array_slice( $argv, 1 ) === $expected ? 0 : 1 );
PHP
chmod +x vendor/bin/changelogger
GITHUB_ACTIONS=true bash "$changelog_check" --optional
expect_failure env GITHUB_ACTIONS=true bash "$changelog_check"

printf 'Significance: patch\nType: fix\n\nOne line.\n' > changelog/entry
git add changelog/entry
git -c user.name=Test -c user.email=test@example.test commit --quiet -m Entry
GITHUB_ACTIONS=true bash "$changelog_check"
GITHUB_ACTIONS=true bash "$changelog_check" --all

printf 'Extra line.\n' >> changelog/entry
expect_failure env GITHUB_ACTIONS=true bash "$changelog_check" --optional
expect_failure env GITHUB_ACTIONS=true bash "$changelog_check" --all
