#!/usr/bin/env bash

version=${RELEASE_VERSION:?Pass the release version}
plugin=${PLUGIN_SLUG:?Pass the plugin slug from trunk}
url="https://translate.wordpress.com/api/import-new-release/woocommerce/$plugin/$version"

echo "Notifying translate.wordpress.com of version $version."
if response=$(curl --silent --show-error --max-time 30 --request POST "$url") &&
    [[ $(jq -r '.success' <<< "$response") == true ]]; then
    echo "Success!"
    exit 0
fi

message="An error occurred while contacting $url. Error: $response."
printf '%s\n' "$message" >&2
channel=${SLACK_CHANNEL:-}
channel=${channel#"${channel%%[![:space:]]*}"}
channel=${channel%"${channel##*[![:space:]]}"}
if [[ -n "${SLACK_WEBHOOK_URL:-}" && -n "$channel" ]]; then
    payload=$(jq -cn --arg text "$message" --arg channel "$channel" '{text: $text, channel: $channel}')
    curl --silent --show-error --max-time 30 --request POST --header 'Content-type: application/json' \
        --data "$payload" "$SLACK_WEBHOOK_URL"
fi
exit 1
