#!/bin/bash
# Collects docker service update state and writes Prometheus textfile metrics.
# Deployed to the Swarm manager (nuc-05) and run every 30s via systemd timer.
set -uo pipefail

OUTDIR=/var/lib/node_exporter/textfile_collector
OUT="$OUTDIR/docker_swarm_update_state.prom"
TMP=$(mktemp "$OUTDIR/tmp_XXXXXX.prom")
trap 'rm -f "$TMP"' EXIT

{
  echo "# HELP docker_service_update_state Docker Swarm service update state (1 = active state)"
  echo "# TYPE docker_service_update_state gauge"

  while IFS= read -r name; do
    state=$(docker service inspect "$name" \
      --format '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}idle{{end}}' 2>/dev/null \
      || echo "unknown")
    printf 'docker_service_update_state{container_label_com_docker_swarm_service_name="%s",update_state="%s"} 1\n' \
      "$name" "$state"
  done < <(docker service ls --format '{{.Name}}')
} > "$TMP"

mv "$TMP" "$OUT"
trap - EXIT