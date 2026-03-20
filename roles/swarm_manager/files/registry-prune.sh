#!/bin/bash
# registry-prune.sh — Remove all but the last N tags from each repo in a local registry.
# Usage: registry-prune.sh [REGISTRY_URL] [KEEP_COUNT]
#
# Requires: regctl (https://github.com/regclient/regclient)

set -euo pipefail

REGISTRY="${1:-localhost:5000}"
KEEP="${2:-2}"

if ! command -v regctl &>/dev/null; then
  echo "ERROR: regctl not found. Install from https://github.com/regclient/regclient" >&2
  exit 1
fi

repos=$(regctl repo ls "$REGISTRY" 2>/dev/null) || {
  echo "ERROR: cannot list repos on $REGISTRY" >&2
  exit 1
}

for repo in $repos; do
  ref="$REGISTRY/$repo"
  # List tags — regctl returns them in order from the registry
  tags=$(regctl tag ls "$ref" 2>/dev/null) || continue
  tag_count=$(echo "$tags" | wc -w)

  if [ "$tag_count" -le "$KEEP" ]; then
    echo "[$repo] $tag_count tag(s), nothing to prune"
    continue
  fi

  # Sort tags by image creation time (newest first) so we keep the truly latest
  tag_entries=()
  for tag in $tags; do
    created=$(regctl image inspect "$ref:$tag" --format '{{.Created}}' 2>/dev/null || echo "1970-01-01T00:00:00Z")
    created="${created// /_}"  # Replace spaces so sort isn't broken by Go timestamps
    tag_entries+=("${created}|${tag}")
  done
  sorted_tags=$(printf '%s\n' "${tag_entries[@]}" | sort -t'|' -k1,1 -r)

  # Keep the first $KEEP, delete the rest
  i=0
  for entry in $sorted_tags; do
    tag="${entry#*|}"
    i=$((i + 1))
    if [ "$i" -le "$KEEP" ]; then
      echo "[$repo] KEEP $tag"
    else
      echo "[$repo] DELETE $tag"
      regctl tag rm "$ref:$tag" 2>/dev/null || echo "[$repo] WARNING: failed to delete $tag"
    fi
  done
done

echo ""
echo "Running garbage collection to reclaim disk space..."
docker exec $(docker ps -q -f name=registry) /bin/registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
echo "Done."
