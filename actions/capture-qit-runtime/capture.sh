#!/usr/bin/env bash

set -euo pipefail

check=$1
results="$GITHUB_WORKSPACE/qit-results"
qit="$GITHUB_WORKSPACE/vendor/bin/qit"
env_id=$(sed -nE 's/^.*Environment ready: (qitenv[0-9a-f]+)[[:space:]]*$/\1/p' "$results/qit-$check-results.txt")

if [[ ! "$env_id" =~ ^qitenv[0-9a-f]+$ ]]; then
    # A runner that failed before printing the environment ID may still need cleanup.
    "$qit" env:down --all -n
    exit 0
fi

trap '"$qit" env:down "$env_id" -n || true' EXIT

command=$(cat <<'COMMAND'
wp eval --skip-plugins --skip-themes 'echo "QIT_RUNTIME ", wp_json_encode( array(
    "wordpress_version" => get_bloginfo( "version" ),
    "woocommerce_version" => get_file_data( WP_PLUGIN_DIR . "/woocommerce/woocommerce.php", array( "version" => "Version" ) )["version"],
    "php_version" => PHP_VERSION
) ), PHP_EOL;'
COMMAND
)

output=$("$qit" env:exec --env_id="$env_id" --timeout=30 -n "$command")
sed -n 's/^QIT_RUNTIME //p' <<< "$output" | jq -ce 'objects' > "$results/$check.runtime.json"
