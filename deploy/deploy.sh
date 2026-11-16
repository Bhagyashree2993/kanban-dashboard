#!/usr/bin/env bash
# =============================================================================
# Blue-green deploy for kanban-dashboard on a single Docker host (EC2).
#
#   Internet :80 ──► kanban-proxy (nginx) ──► kanban-blue  :3000   (live)
#                                        └ ─► kanban-green :3000   (new)
#
# Usage:
#   deploy.sh deploy   <image:tag> <expected-version>
#   deploy.sh rollback                 # redeploy the previously-live image
#   deploy.sh status                   # evidence: ps / health / limits / logs
#
# Flow (deploy):
#   1. pull image          2. start NEW colour next to the OLD one (with limits)
#   3. wait for Docker HEALTHCHECK = healthy
#   4. smoke-test NEW directly (version.json + index.html)
#   5. switch proxy upstream -> NEW, graceful `nginx -s reload` (no dropped conns)
#   6. verify through the proxy; if it fails, switch back to OLD
#   7. only then stop/remove OLD
# Any failure before step 7 leaves the OLD container serving traffic.
# =============================================================================
set -Eeuo pipefail

APP=kanban
NETWORK="${APP}-net"
PROXY="${APP}-proxy"
PROXY_IMAGE="${PROXY_IMAGE:-nginxinc/nginx-unprivileged:1.27-alpine}"
HOST_PORT="${HOST_PORT:-80}"
APP_PORT=3000
STATE_DIR="${STATE_DIR:-/opt/kanban}"
PROXY_CONF_DIR="${STATE_DIR}/proxy"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"   # seconds
DRAIN_SECONDS="${DRAIN_SECONDS:-5}"

# --- Resource limits (see README "Resource limits" for the reasoning) -------
APP_MEMORY="${APP_MEMORY:-128m}"
APP_MEMORY_RESERVATION="${APP_MEMORY_RESERVATION:-64m}"
APP_CPUS="${APP_CPUS:-0.25}"
APP_PIDS="${APP_PIDS:-100}"
PROXY_MEMORY="${PROXY_MEMORY:-64m}"
PROXY_CPUS="${PROXY_CPUS:-0.25}"

log()  { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '[deploy %s] ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

mkdir -p "$PROXY_CONF_DIR" 2>/dev/null || true

# One deploy at a time on this host (status is read-only and skips the lock).
take_lock() {
  umask 002
  exec 9>>"${STATE_DIR}/deploy.lock"
  flock -w 300 9 || fail "another deploy is running"
}

active_colour() { cat "${STATE_DIR}/active_colour" 2>/dev/null || true; }
other_colour()  { [[ "$1" == "blue" ]] && echo green || echo blue; }
running()       { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

write_proxy_conf() {   # $1 = colour to route to
  cat > "${PROXY_CONF_DIR}/default.conf.tmp" <<EOF
# Managed by deploy.sh — live colour: $1
upstream kanban_app { server ${APP}-$1:${APP_PORT}; }
server {
    listen 8080;
    server_tokens off;
    location = /proxy-health { access_log off; default_type text/plain; return 200 "ok\n"; }
    location / {
        proxy_pass http://kanban_app;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        add_header X-Served-By ${APP}-$1 always;
    }
}
EOF
  mv "${PROXY_CONF_DIR}/default.conf.tmp" "${PROXY_CONF_DIR}/default.conf"
}

ensure_network() {
  docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
}

ensure_proxy() {       # $1 = colour to route to
  if running "$PROXY"; then return 0; fi
  log "starting proxy ${PROXY} on host port ${HOST_PORT}"
  docker rm -f "$PROXY" >/dev/null 2>&1 || true
  write_proxy_conf "$1"
  docker run -d --name "$PROXY" \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p "${HOST_PORT}:8080" \
    -v "${PROXY_CONF_DIR}:/etc/nginx/conf.d:ro" \
    --memory "$PROXY_MEMORY" --memory-swap "$PROXY_MEMORY" --cpus "$PROXY_CPUS" \
    --pids-limit 100 --cap-drop ALL --security-opt no-new-privileges \
    --log-opt max-size=10m --log-opt max-file=3 \
    "$PROXY_IMAGE" >/dev/null
  local i
  for i in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:${HOST_PORT}/proxy-health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  docker logs --tail 30 "$PROXY" 2>&1 || true
  fail "proxy did not come up on port ${HOST_PORT}"
}

switch_proxy() {       # $1 = colour to route to
  write_proxy_conf "$1"
  docker exec "$PROXY" nginx -t >/dev/null 2>&1 || return 1
  docker exec "$PROXY" nginx -s reload       # graceful: old workers finish in-flight requests
}

wait_healthy() {       # $1 = container
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) status
  while (( SECONDS < deadline )); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo missing)"
    case "$status" in
      healthy)   log "$1 is healthy"; return 0 ;;
      unhealthy|missing) log "$1 status=$status"; return 1 ;;
    esac
    running "$1" || { log "$1 exited"; return 1; }
    sleep 2
  done
  log "$1 not healthy after ${HEALTH_TIMEOUT}s"; return 1
}

smoke_test_container() {   # $1 = container, $2 = expected version
  local body
  body="$(docker exec "$1" wget -qO- "http://127.0.0.1:${APP_PORT}/version.json")" || return 1
  [[ "$body" == *"\"$2\""* ]] || { log "version mismatch: got $body expected $2"; return 1; }
  docker exec "$1" wget -qO- "http://127.0.0.1:${APP_PORT}/" | grep -q 'id="root"' || { log "index.html check failed"; return 1; }
}

smoke_test_proxy() {       # $1 = expected version
  local i
  for i in $(seq 1 10); do
    if curl -fsS "http://127.0.0.1:${HOST_PORT}/version.json" | grep -q "\"$1\""; then return 0; fi
    sleep 1
  done
  return 1
}

dump_failure() {           # $1 = container
  log "---- docker inspect health ($1) ----"
  docker inspect -f '{{json .State.Health}}' "$1" 2>/dev/null || true
  log "---- last 50 log lines ($1) ----"
  docker logs --tail 50 "$1" 2>&1 || true
}

do_deploy() {
  local image="$1" version="$2" mode="${3:-deploy}"
  local old new
  old="$(active_colour)"
  [[ -n "$old" ]] && running "${APP}-${old}" || old=""
  new="$(other_colour "${old:-green}")"

  log "image=${image} version=${version} live=${old:-none} -> new=${new}"
  docker pull "$image"
  ensure_network

  docker rm -f "${APP}-${new}" >/dev/null 2>&1 || true
  log "starting ${APP}-${new} (mem=${APP_MEMORY}, cpus=${APP_CPUS})"
  docker run -d --name "${APP}-${new}" \
    --network "$NETWORK" \
    --restart unless-stopped \
    --memory "$APP_MEMORY" --memory-swap "$APP_MEMORY" --memory-reservation "$APP_MEMORY_RESERVATION" \
    --cpus "$APP_CPUS" --pids-limit "$APP_PIDS" \
    --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
    --cap-drop ALL --security-opt no-new-privileges \
    --log-opt max-size=10m --log-opt max-file=3 \
    --label app="$APP" --label colour="$new" --label version="$version" \
    "$image" >/dev/null

  if ! wait_healthy "${APP}-${new}" || ! smoke_test_container "${APP}-${new}" "$version"; then
    dump_failure "${APP}-${new}"
    docker rm -f "${APP}-${new}" >/dev/null 2>&1 || true
    fail "new container failed health checks — traffic stays on ${old:-<nothing>}"
  fi

  ensure_proxy "$new"
  log "switching proxy -> ${new}"
  if ! switch_proxy "$new" || ! smoke_test_proxy "$version"; then
    if [[ -n "$old" ]]; then
      log "proxy verification failed, switching back to ${old}"
      switch_proxy "$old" || true
    fi
    dump_failure "${APP}-${new}"
    docker rm -f "${APP}-${new}" >/dev/null 2>&1 || true
    fail "verification through proxy failed"
  fi

  # Record state.
  if [[ "$mode" == "deploy" ]]; then
    cp -f "${STATE_DIR}/current_image" "${STATE_DIR}/previous_image" 2>/dev/null || true
  fi
  echo "$new"     > "${STATE_DIR}/active_colour"
  echo "$image"   > "${STATE_DIR}/current_image"
  echo "$(date -u +%FT%TZ) ${mode} ${image} -> ${new}" >> "${STATE_DIR}/history.log"

  if [[ -n "$old" ]]; then
    log "draining ${APP}-${old} for ${DRAIN_SECONDS}s, then removing"
    sleep "$DRAIN_SECONDS"
    docker stop -t 10 "${APP}-${old}" >/dev/null || true
    docker rm "${APP}-${old}" >/dev/null || true
  fi
  docker image prune -f >/dev/null || true
  log "SUCCESS: ${image} live on :${HOST_PORT} via ${APP}-${new}"
}

do_rollback() {
  local prev
  prev="$(cat "${STATE_DIR}/previous_image" 2>/dev/null || true)"
  [[ -n "$prev" ]] || fail "no previous image recorded — nothing to roll back to"
  log "ROLLBACK to ${prev}"
  do_deploy "$prev" "${prev##*:}" rollback
}

do_status() {
  echo "== docker ps =="
  docker ps --filter "name=${APP}-" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  local c="${APP}-$(active_colour)"
  echo; echo "== live container: $c =="
  docker inspect -f 'User={{.Config.User}}  Health={{.State.Health.Status}}  Memory={{.HostConfig.Memory}}B  NanoCPUs={{.HostConfig.NanoCpus}}  ReadOnly={{.HostConfig.ReadonlyRootfs}}' "$c" || true
  echo; echo "== docker stats =="
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' "$c" "$PROXY" || true
  echo; echo "== curl version.json =="
  curl -fsS "http://127.0.0.1:${HOST_PORT}/version.json" || true
  echo; echo "== last 10 log lines =="
  docker logs --tail 10 "$c" 2>&1 || true
  echo; echo "== history =="
  tail -n 10 "${STATE_DIR}/history.log" 2>/dev/null || true
}

case "${1:-}" in
  deploy)   [[ $# -eq 3 ]] || fail "usage: $0 deploy <image:tag> <version>"; take_lock; do_deploy "$2" "$3" deploy ;;
  rollback) take_lock; do_rollback ;;
  status)   do_status ;;
  *)        fail "usage: $0 {deploy <image:tag> <version>|rollback|status}" ;;
esac
