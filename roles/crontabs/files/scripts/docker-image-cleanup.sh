#!/bin/bash
# docker-image-cleanup.sh — Remove old Docker images, keeping the two most
# recent for each repository. Images actively used by Swarm services are
# always preserved.
#
# Managed by Ansible — do not edit manually

set -euo pipefail

KEEP=2
LOG_TAG="docker-image-cleanup"

log() { logger -t "$LOG_TAG" "$*"; echo "$*"; }

# Collect image IDs currently in use by any Swarm service or running container
in_use=$(
  {
    docker service ls --format '{{.Image}}' 2>/dev/null
    docker ps --format '{{.Image}}' 2>/dev/null
  } | sort -u | while read -r img; do
    # Resolve to image ID (handles both tag and digest references)
    docker image inspect --format '{{.Id}}' "$img" 2>/dev/null || true
  done | sort -u
)

# Build list of all local images grouped by repository
# Format: repo<TAB>tag<TAB>image_id<TAB>created_unix
images=$(docker images --format '{{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.CreatedAt}}' \
  | grep -v '<none>' \
  | sort)

if [ -z "$images" ]; then
  log "No images found, nothing to clean."
  exit 0
fi

removed=0
kept=0

# Process each repository: keep the KEEP most recent images, remove the rest
echo "$images" \
  | awk -F'\t' '{print $1}' \
  | sort -u \
  | while read -r repo; do

  # Get all tags for this repo, sorted newest first by creation date
  repo_images=$(echo "$images" | awk -F'\t' -v r="$repo" '$1 == r' | sort -t$'\t' -k4 -r)
  count=0

  echo "$repo_images" | while IFS=$'\t' read -r _repo tag id created; do
    count=$((count + 1))

    # Always keep the N most recent
    if [ "$count" -le "$KEEP" ]; then
      log "KEEP  ${_repo}:${tag} (#${count}, ${created})"
      continue
    fi

    # Never remove images in use by running services
    if echo "$in_use" | grep -q "$id"; then
      log "KEEP  ${_repo}:${tag} (in use by service)"
      continue
    fi

    log "REMOVE ${_repo}:${tag} (${created})"
    docker rmi "${_repo}:${tag}" 2>/dev/null || log "WARN: failed to remove ${_repo}:${tag}"
  done
done

# Clean up dangling images and build cache
docker image prune -f > /dev/null 2>&1

log "Cleanup complete."
