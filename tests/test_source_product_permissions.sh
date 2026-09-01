#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
source "${ROOT}/client/lib/dp-offline-source-product-version.sh"

# Existing parent 0755 must not be chmod'd to 0700.
parent="$TMP/shared-offline"
mkdir -p "$parent"
chmod 0755 "$parent"
dest="${parent}/source-product.env"
printf 'SOURCE_DP_VERSION=6.5.0\nSOURCE_DP_VERSION_NORMALIZED=6.5.0\nSOURCE_DP_VERSION_ORIGIN=test\n' \
  | spv_atomic_write_file "$dest" 0600
mode_parent="$(stat -c '%a' "$parent")"
mode_file="$(stat -c '%a' "$dest")"
[[ "$mode_parent" == "755" ]] || { echo "FAIL parent mode changed to $mode_parent"; exit 1; }
[[ "$mode_file" == "600" ]] || { echo "FAIL file mode $mode_file"; exit 1; }
echo "PASS existing parent 0755 preserved"

# Existing parent 0700 remains 0700
parent2="$TMP/private-offline"
mkdir -p "$parent2"
chmod 0700 "$parent2"
dest2="${parent2}/source-product.env"
printf 'SOURCE_DP_VERSION=6.5.0\nSOURCE_DP_VERSION_NORMALIZED=6.5.0\nSOURCE_DP_VERSION_ORIGIN=test\n' \
  | spv_atomic_write_file "$dest2" 0600
[[ "$(stat -c '%a' "$parent2")" == "700" ]] || { echo "FAIL 0700 parent altered"; exit 1; }
[[ "$(stat -c '%a' "$dest2")" == "600" ]] || { echo "FAIL file mode"; exit 1; }
echo "PASS existing parent 0700 preserved"

# New dedicated directory gets 0700
new_parent="$TMP/new-only/offline"
dest3="${new_parent}/source-product.env"
printf 'SOURCE_DP_VERSION=6.5.0\nSOURCE_DP_VERSION_NORMALIZED=6.5.0\nSOURCE_DP_VERSION_ORIGIN=test\n' \
  | spv_atomic_write_file "$dest3" 0600
[[ "$(stat -c '%a' "$new_parent")" == "700" ]] || { echo "FAIL new parent mode"; exit 1; }
[[ "$(stat -c '%a' "$dest3")" == "600" ]] || { echo "FAIL new file mode"; exit 1; }
echo "PASS new dedicated directory mode"

echo "PASS test_source_product_permissions"
