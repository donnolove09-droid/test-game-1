#!/usr/bin/env bash
# Point the H5 client at your Render host.
# Usage: patch-client.sh <client_dir> <host>      e.g.  patch-client.sh app/www loli-game.onrender.com
set -euo pipefail

DIR="${1:?usage: patch-client.sh <client_dir> <host>}"
HOST="${2:?usage: patch-client.sh <client_dir> <host>}"
OLD_IP="${OLD_IP:-192.168.1.234}"

[[ "$HOST" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "Invalid host: $HOST"; exit 1; }
[ -d "$DIR/assets/main" ] || { echo "Not a client dir (no assets/main): $DIR"; exit 1; }
export HOST OLD_IP

# 1) Scene config: apiUrl (http://IP:9001 or http://IP:1010/) and socketPre (IP:81/game?)
n_json=0
while IFS= read -r f; do
  perl -pi -e 's#http://\Q$ENV{OLD_IP}\E:(?:9001|1010)/?#https://$ENV{HOST}#g; s#\Q$ENV{OLD_IP}\E:81/game\?#$ENV{HOST}/game?#g' "$f"
  n_json=$((n_json + 1))
done < <(grep -rlF "$OLD_IP" "$DIR/assets/main" 2>/dev/null || true)

# 2) Game bundle: if the scene has no socketPre, fall back to HOST/game?
n_js=0
for f in "$DIR"/assets/Game/index.*.js; do
  [ -f "$f" ] || continue
  if grep -q 'AppConfig\.socketPre+"ip="' "$f"; then
    perl -pi -e 's#"wss://"\+(\w+)\.AppConfig\.socketPre\+"ip="#"wss://"+($1.AppConfig.socketPre||"$ENV{HOST}/game?")+"ip="#g' "$f"
    n_js=$((n_js + 1))
  fi
done

left=$(grep -rlF "$OLD_IP" "$DIR/assets" 2>/dev/null | wc -l || true)
echo "[patch-client] host=$HOST  scene json patched=$n_json  game js patched=$n_js  files still containing $OLD_IP: $left"
