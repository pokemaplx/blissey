#!/usr/bin/env bash
# Container start: wait for the database, validate the config, apply schema/migrations,
# then hand over to supercronic which runs `blissey tick` every 5 minutes.
#
# Any arguments are executed instead (e.g. `docker compose run --rm blissey blissey check`).

set -euo pipefail
cd /blissey

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

export BLISSEY_ROOT=/blissey
# shellcheck source=../lib/common.sh
source /blissey/lib/common.sh
# shellcheck source=../lib/config.sh
source /blissey/lib/config.sh
load_config

echo "Blissey starting (TZ=${TZ:-UTC}, data dir $BLISSEY_DATA_DIR)"
for attempt in $(seq 1 30); do
  if mysql_blissey -NB -e "select 1" > /dev/null 2>&1; then
    break
  fi
  if (( attempt == 30 )); then
    echo "database $database_stats@$database_host:$database_port not reachable after 60s, giving up" >&2
    exit 1
  fi
  echo "waiting for database $database_host:$database_port ($attempt/30)"
  sleep 2
done

bin/blissey check
bin/blissey setup

echo "Starting scheduler"
# absolute path: supercronic re-executes itself (argv[0]) to reap zombies when it is PID 1
exec /usr/local/bin/supercronic /blissey/docker/crontab
