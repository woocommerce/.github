#!/usr/bin/env bash

# The workflow supplies the verified archive and the product ID from trunk.
ASSET=${RELEASE_ARCHIVE:-}
if [[ ! "$PRODUCT_ID" =~ ^[1-9][0-9]*$ ]]; then
  echo "config.woo.release.productId must be the WooCommerce.com product ID." >&2
  exit 1
fi

mode=${1:-}
if [[ ! "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "A release version in X.Y.Z format is required." >&2
  exit 1
fi

# The submission endpoint only reports active deploys. The public product
# endpoint reports the version in the marketplace's published changelog.
published_version() {
  curl --silent --show-error --fail --max-time 30 --proto '=https' --tlsv1.2 \
    --get --data-urlencode "product_id=$PRODUCT_ID" https://woocommerce.com/wp-json/helper/1.0/info |
    jq -er '.version | strings | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))'
}

if [[ "$mode" == confirm ]]; then
  # Allow time for the marketplace to finish deployment and refresh its update data.
  # Keep fleet releases within the shared product-info request limit.
  deadline=$((SECONDS + 3600))
  while :; do
    if version=$(published_version) && [[ "$version" == "$RELEASE_VERSION" ]]; then
      echo "WooCommerce.com is offering version ${RELEASE_VERSION}."
      exit 0
    fi
    (( SECONDS < deadline )) || break
    sleep 300
  done
  echo "WooCommerce.com has not confirmed version ${RELEASE_VERSION}. Check the Marketplace dashboard before re-running failed jobs." >&2
  exit 1
fi

if [[ "$mode" != prepare && "$mode" != submit ]] || [[ ! "$RELEASE_SHA256" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "Pass prepare or submit with a release version and SHA-256, or confirm with a release version." >&2
  exit 1
fi

if [ ! -s "$ASSET" ]; then
  echo "Released archive is missing or empty." >&2
  exit 1
fi

if ! jq -e --arg version "$RELEASE_VERSION" '.version == $version' package.json > /dev/null; then
  echo "Release version does not match package.json." >&2
  exit 1
fi

if ! printf '%s  %s\n' "$RELEASE_SHA256" "$ASSET" | sha256sum -c - > /dev/null; then
  echo "Released archive checksum does not match." >&2
  exit 1
fi

deploy_url=https://woocommerce.com/wp-json/wc/submission/runner/v1/product/deploy
credentials=(--form-string "product_id=${PRODUCT_ID}" --form-string "username=${DEPLOY_API_KEY}" --form-string "password=${DEPLOY_API_SECRET}")

if [[ "$mode" == prepare ]]; then
  version=$(published_version) || { echo "Could not read the current WooCommerce.com version." >&2; exit 1; }
  if [[ "$version" == "$RELEASE_VERSION" ]]; then
    echo "Version ${RELEASE_VERSION} is already live on WooCommerce.com."
    exit 0
  fi
  if [[ $(printf '%s\n' "$version" "$RELEASE_VERSION" | sort -V | tail -n 1) == "$version" ]]; then
    echo "WooCommerce.com already offers newer version ${version}." >&2
    exit 1
  fi

  if response=$(curl --silent --show-error --max-time 30 --proto '=https' --tlsv1.2 --fail-with-body \
    "${credentials[@]}" "${deploy_url}/status"); then
    if jq -e --arg version "$RELEASE_VERSION" '.version == $version and (.status | type == "string" and length > 0) and .status != "failed"' <<< "$response" > /dev/null; then
      echo "WooCommerce.com already has version ${RELEASE_VERSION} in progress."
      exit 0
    fi
    echo "WooCommerce.com reports another or failed submission. Check the Marketplace dashboard." >&2
    exit 1
  elif ! jq -e '.code == "submission_runner_no_deploy_in_progress"' <<< "$response" > /dev/null; then
    jq -r '.message // "WooCommerce.com status request failed."' <<< "$response" >&2
    exit 1
  fi

  # A prior attempt may have sent the ZIP even if its runner did not get a response.
  # With no version in progress, the Marketplace dashboard is needed to tell the difference.
  if [[ ${UPLOAD_PREVIOUSLY_ATTEMPTED:-false} == true ]]; then
    echo "An earlier attempt may have sent this ZIP. Check the Marketplace dashboard before submitting it again." >&2
    exit 1
  fi
  echo "upload=true" >> "$GITHUB_OUTPUT"
  exit 0
fi

response=$(curl --silent --show-error --max-time 120 --proto '=https' --tlsv1.2 --fail-with-body \
  "${credentials[@]}" -F "file=@./${ASSET}" --form-string "version=${RELEASE_VERSION}" "$deploy_url") ||
  { jq -r '.message // "WooCommerce.com did not confirm the upload."' <<< "$response" >&2; exit 1; }
if ! jq -e '.success == true' <<< "$response" > /dev/null; then
  echo "WooCommerce.com did not confirm the upload." >&2
  exit 1
fi

echo "WooCommerce.com accepted version ${RELEASE_VERSION} for deployment."
