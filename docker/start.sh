#!/usr/bin/env bash
# Entry point of the Render web service.
#   nginx (public $PORT):  /api -> backstage :9001   /game -> game_server :10001 (WebSocket)   / -> H5 client
set -u

log() { echo "[start] $*"; }

export PORT="${PORT:-10000}"
export PUBLIC_HOST="${PUBLIC_HOST:-${RENDER_EXTERNAL_HOSTNAME:-localhost}}"
export DB_HOST="${DB_HOST:-127.0.0.1}"
export DB_PORT="${DB_PORT:-3306}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-yy2024}"
: "${DB_PASSWORD:?DB_PASSWORD is not set}"
export DB_PASSWORD

XMX_BACKSTAGE="${XMX_BACKSTAGE:-128m}"
XMX_GAME="${XMX_GAME:-448m}"
XMX_CROSS="${XMX_CROSS:-192m}"
ENABLE_CROSS="${ENABLE_CROSS:-1}"
JAVA_OPTS_COMMON="${JAVA_OPTS_COMMON:--XX:+UseSerialGC -XX:MaxMetaspaceSize=160m -XX:ReservedCodeCacheSize=64m -XX:+ExitOnOutOfMemoryError}"
LIBS="/home/game/x1/common-libs/*"

PIDS=()
declare -A NAME=()
track() { PIDS+=("$1"); NAME[$1]="$2"; }

cleanup() {
  trap - EXIT
  log "stopping services..."
  local pid i alive
  for pid in "${PIDS[@]}"; do kill -TERM "$pid" 2>/dev/null; done
  for ((i = 0; i < 25; i++)); do
    alive=0
    for pid in "${PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" = 0 ] && break
    sleep 1
  done
  for pid in "${PIDS[@]}"; do kill -KILL "$pid" 2>/dev/null; done
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# ---- 1. config: DB host/password and Redis password ------------------------------------------
log "host=$PUBLIC_HOST  db=$DB_HOST:$DB_PORT"
for svc in backstage game_server cross-server; do
  for f in "/home/$svc/config/database.db" "/home/$svc/config/application.properties"; do
    [ -f "$f" ] || { log "missing $f"; exit 1; }
  done
  perl -pi -e 's/"ipPort":"[^"]*"/"ipPort":"$ENV{DB_HOST}:$ENV{DB_PORT}"/g; s/"password":"[^"]*"/"password":"$ENV{DB_PASSWORD}"/g' "/home/$svc/config/database.db"
  perl -pi -e 's/^spring\.redis\.password=.*$/spring.redis.password=$ENV{REDIS_PASSWORD}/' "/home/$svc/config/application.properties"
done
patch-client.sh /srv/game "$PUBLIC_HOST" || exit 1

# ---- 2. nginx first, so Render's health check passes while the JVMs boot ----------------------
envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
nginx -t || exit 1
nginx -g 'daemon off;' &
track $! nginx

# ---- 3. redis (local, not persisted) -----------------------------------------------------------
redis-server --bind 127.0.0.1 --port 6379 --requirepass "$REDIS_PASSWORD" --save "" --appendonly no \
  --maxmemory "${REDIS_MAXMEMORY:-128mb}" > >(sed -u 's/^/[redis] /') 2>&1 &
track $! redis

# ---- 4. wait for MySQL, create + import databases on first start -----------------------------
export MYSQL_PWD="$DB_PASSWORD"
MYSQL=(mysql -h"$DB_HOST" -P"$DB_PORT" -uroot --default-character-set=utf8mb4)

log "waiting for MySQL at $DB_HOST:$DB_PORT ..."
ok=0
for ((i = 0; i < 150; i++)); do
  if "${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1; then ok=1; break; fi
  sleep 2
done
[ "$ok" = 1 ] || { log "MySQL is not reachable"; exit 1; }

init_db() {
  if "${MYSQL[@]}" -N -e "SHOW DATABASES LIKE 'x1_init_done'" | grep -qx x1_init_done; then
    log "databases already initialised"
    return 0
  fi
  log "first start: creating databases and importing SQL"
  local db
  for db in x1_backstage x1_backlog x1_4_log x1_4_game x1_cross_data x1_cross_log; do
    "${MYSQL[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$db\` DEFAULT CHARACTER SET utf8 COLLATE utf8_general_ci" || return 1
  done
  # server list: use this Render host and the wss gateway (/game)
  perl -pe 's/\x27ws\x27,\x27192\.168\.1\.234\x27/\x27wss\x27,\x27$ENV{PUBLIC_HOST}\x27/g; s/192\.168\.1\.234/$ENV{PUBLIC_HOST}/g' \
    /home/sql/x1_backstage.sql > /tmp/x1_backstage.sql || return 1
  "${MYSQL[@]}" x1_backstage   < /tmp/x1_backstage.sql          || return 1
  "${MYSQL[@]}" x1_backlog     < /home/sql/x1_backlog.sql       || return 1
  "${MYSQL[@]}" x1_4_log       < /home/sql/x1_4_log.sql         || return 1
  "${MYSQL[@]}" x1_4_game      < /home/sql/x1_4_game.sql        || return 1
  "${MYSQL[@]}" x1_cross_data  < /home/sql/x1_cross_data.sql    || return 1
  "${MYSQL[@]}" x1_cross_log   < /home/sql/x1_cross_log.sql     || return 1
  "${MYSQL[@]}" -e "CREATE DATABASE x1_init_done" || return 1
  log "database import finished"
}
init_db || { log "database initialisation failed"; exit 1; }

# ---- 5. the three Java services (same classpath/main classes as the original restart scripts) --
start_java() {  # name dir xmx main [agent_jar]
  local name="$1" dir="$2" xmx="$3" main="$4" agent="${5:-}"
  local opts=(-server)
  [ -n "$agent" ] && opts+=("-javaagent:$agent")
  ( cd "$dir" && exec java "${opts[@]}" $JAVA_OPTS_COMMON -Xms64m -Xmx"$xmx" \
      -classpath "$dir/config/*:$LIBS:$dir/jar/*:" "$main" ) \
    > >(sed -u "s/^/[$name] /") 2>&1 &
  track $! "$name"
}

wait_port() {  # name pid port timeout_seconds
  local name="$1" pid="$2" port="$3" t="${4:-300}" i
  for ((i = 0; i < t; i++)); do
    kill -0 "$pid" 2>/dev/null || { log "$name exited during startup"; return 1; }
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then log "$name is up on :$port"; return 0; fi
    sleep 1
  done
  log "$name did not open :$port within ${t}s"
  return 1
}

start_java backstage /home/backstage "$XMX_BACKSTAGE" com.xiugou.x1.backstage.X1BackStage
wait_port backstage "${PIDS[-1]}" 9001 || exit 1

if [ "$ENABLE_CROSS" = 1 ]; then
  start_java cross /home/cross-server "$XMX_CROSS" com.xiugou.x1.cross.server.X1CrossServer \
    /home/cross-server/jar/gaming-agent-0.0.1.jar
  wait_port cross "${PIDS[-1]}" 41001 || exit 1
fi

start_java game /home/game_server "$XMX_GAME" com.xiugou.x1.game.server.X1GameServer \
  /home/game_server/jar/gaming-agent-0.0.1.jar
wait_port game "${PIDS[-1]}" 10001 || exit 1

log "READY  ->  https://$PUBLIC_HOST/"

# ---- 6. supervise: if anything dies, exit so Render restarts the whole service -----------------
wait -n "${PIDS[@]}"
for pid in "${PIDS[@]}"; do
  kill -0 "$pid" 2>/dev/null || log "process '${NAME[$pid]:-?}' exited"
done
exit 1
