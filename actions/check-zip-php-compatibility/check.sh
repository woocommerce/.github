#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

unzip -q "$ARCHIVE" -d "$scratch/package"
plugin="$scratch/package/$PLUGIN_ROOT"
if [[ ! -f "$plugin/$MAIN_FILE" ]]; then
    echo "::error::The production ZIP is missing $PLUGIN_ROOT/$MAIN_FILE."
    exit 1
fi

args=()
if [[ -n "$RULESET" ]]; then
    tools=tools/php-quality
    standard="$RULESET"
else
    if [[ -z "$TEST_VERSION" ]]; then
        echo "::error::Set a PHP version range to use the shared PHPCompatibilityWP rules."
        exit 1
    fi
    tools="$scratch/tools"
    mkdir "$tools"
    cp "$GITHUB_ACTION_PATH/composer.json" "$GITHUB_ACTION_PATH/composer.lock" "$tools/"
    standard=PHPCompatibilityWP
    args+=('--extensions=php,inc')
fi

if [[ -n "$TEST_VERSION" ]]; then
    args+=(--runtime-set testVersion "$TEST_VERSION")
fi
if [[ -n "$IGNORE" ]]; then
    args+=(--ignore="$IGNORE")
fi

composer --working-dir="$tools" install --no-interaction --prefer-dist --no-progress
php "$tools/vendor/bin/phpcs" --standard="$standard" -ps --basepath="$plugin" "${args[@]}" "$plugin"
