#!/usr/bin/env bash
# Shared helpers for every Blissey command. Sourced by bin/blissey, never executed directly.
# Configuration loading lives in lib/config.sh.
#
# Environment overrides (all optional):
#   BLISSEY_ROOT        repository root (auto-detected from bin/blissey)
#   BLISSEY_CONFIG      path to config.toml           (default: $BLISSEY_ROOT/config.toml)
#   BLISSEY_DATA_DIR    logs/tmp/backups directory    (default: $BLISSEY_ROOT/data)
#   BLISSEY_LOG_STDOUT  1 = also print log lines to stdout (set in the Docker image)
#   BLISSEY_DRY_RUN     1 = print mysql/mysqldump commands instead of executing them

set -o pipefail
set -u

BLISSEY_ROOT="${BLISSEY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BLISSEY_CONFIG="${BLISSEY_CONFIG:-$BLISSEY_ROOT/config.toml}"
BLISSEY_DATA_DIR="${BLISSEY_DATA_DIR:-$BLISSEY_ROOT/data}"

SQL_DIR="$BLISSEY_ROOT/sql"
LIB_DIR="$BLISSEY_ROOT/lib"
TOOLS_DIR="$BLISSEY_ROOT/tools"
LOG_DIR="$BLISSEY_DATA_DIR/logs"
TMP_DIR="$BLISSEY_DATA_DIR/tmp"
BACKUP_DIR="$BLISSEY_DATA_DIR/backups"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

now() { date '+%Y%m%d %H:%M:%S'; }

log_file() { echo "$LOG_DIR/log_$(date '+%Y%m').log"; }

# log <text> — append a line to the monthly log (and stdout when BLISSEY_LOG_STDOUT=1)
log() {
  mkdir -p "$LOG_DIR"
  echo "$*" >> "$(log_file)"
  [[ "${BLISSEY_LOG_STDOUT:-0}" == 1 ]] && echo "$*"
  return 0
}

warn() { echo "WARNING: $*" >&2; }

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Send stderr of the current process to the monthly log so mysql/curl errors end up
# next to the timing lines (tee'd to the console in Docker).
redirect_stderr_to_log() {
  mkdir -p "$LOG_DIR"
  if [[ "${BLISSEY_LOG_STDOUT:-0}" == 1 ]]; then
    exec 2> >(tee -a "$(log_file)" >&2)
  else
    exec 2>> "$(log_file)"
  fi
}

# timed <label> <command...> — run a command and log "[start] [stop] [mm:ss] label"
timed() {
  local label=$1; shift
  local start stop s0 s1 rc diff
  start=$(now); s0=$(date +%s)
  "$@"; rc=$?
  stop=$(now); s1=$(date +%s)
  diff=$(printf '%02dm:%02ds' $(( (s1 - s0) / 60 )) $(( (s1 - s0) % 60 )))
  if (( rc == 0 )); then
    log "[$start] [$stop] [$diff] $label"
  else
    log "[$start] [$stop] [$diff] $label FAILED (rc=$rc)"
  fi
  return $rc
}

is_true() { [[ "${1:-false}" == "true" ]]; }

# ---------------------------------------------------------------------------
# MySQL / MariaDB access
# ---------------------------------------------------------------------------

scanner_host() { echo "${database_golbat_host:-$database_host}"; }

# _mysql_as <user> <password> <host> <database> [mysql args...]   (SQL comes from -e or stdin)
_mysql_as() {
  local user=$1 pass=$2 host=$3 db=$4; shift 4
  if [[ "${BLISSEY_DRY_RUN:-0}" == 1 ]]; then
    echo "DRY-RUN: mysql -u$user -h$host -P$database_port $db $*"
    [[ -t 0 ]] || timeout 2 cat   # show piped SQL; give up quickly on an idle stdin
    return 0
  fi
  MYSQL_PWD="$pass" mysql -u"$user" -h"$host" -P"$database_port" "$db" "$@"
}

# _mysql <host> <database> [mysql args...] — with the main credentials
_mysql() { _mysql_as "$database_user" "$database_password" "$@"; }

mysql_blissey()   { _mysql "$database_host" "$database_stats" "$@"; }
mysql_dragonite() { _mysql "$database_host" "$database_dragonite" "$@"; }
mysql_scanner()   { _mysql "$(scanner_host)" "$database_golbat" "$@"; }
# central database of a multi-instance setup (own credentials, same server)
mysql_multi()     { _mysql_as "$multi_instance_user" "$multi_instance_password" "$database_host" "$multi_instance_database" "$@"; }

# _mysqldump <host> [mysqldump args...]  (database name is part of the args)
_mysqldump() {
  local host=$1; shift
  if [[ "${BLISSEY_DRY_RUN:-0}" == 1 ]]; then
    echo "DRY-RUN: mysqldump -h$host -P$database_port $*"
    return 0
  fi
  MYSQL_PWD="$database_password" mysqldump -u"$database_user" -h"$host" -P"$database_port" "$@"
}

mysqldump_dragonite() { _mysqldump "$database_host" "$@"; }
mysqldump_scanner()   { _mysqldump "$(scanner_host)" "$@"; }

# sql_substitute <file> — print a SQL file with the placeholder database names
# (blissey. / golbat. / dragonite. / koji. / singleblissey. / multiblissey.) replaced by the
# configured ones.
sql_substitute() {
  sed -e "s/\bblissey\./${database_stats}./g" \
      -e "s/\bsingleblissey\./${database_stats}./g" \
      -e "s/\bmultiblissey\./${multi_instance_database}./g" \
      -e "s/\bgolbat\./${database_golbat}./g" \
      -e "s/\bdragonite\./${database_dragonite}./g" \
      -e "s/\bkoji\./${database_koji}./g" "$1"
}

# sql_run <blissey|scanner|dragonite|multi> <file> [mysql args...]
sql_run() {
  local target=$1 file=$2; shift 2
  [[ -f "$file" ]] || { echo "SQL file not found: $file" >&2; return 1; }
  if [[ "${BLISSEY_DRY_RUN:-0}" == 1 ]]; then
    echo "DRY-RUN: $file -> $target"
    return 0
  fi
  sql_substitute "$file" | "mysql_$target" "$@"
}

# ---------------------------------------------------------------------------
# Small numeric helpers used by the log parsers
# ---------------------------------------------------------------------------

# agg <min|max|sum|avg> — aggregate the numbers on stdin (one per line); 0 when empty
agg() {
  awk -v op="$1" '
    NF { n++; v = $1 + 0; s += v; if (n == 1 || v < mn) mn = v; if (n == 1 || v > mx) mx = v }
    END {
      if (!n) { print 0; exit }
      if (op == "min") r = mn; else if (op == "max") r = mx; else if (op == "sum") r = s; else r = s / n
      if (r == int(r)) printf "%d\n", r; else printf "%.3f\n", r
    }'
}

# durations_ms — convert Go duration strings on stdin ("1m2.5s", "456ms", "12µs") to milliseconds
durations_ms()  { awk -f "$LIB_DIR/duration.awk"; }
# durations_min — same, truncated to whole minutes
durations_min() { awk -v unit=min -f "$LIB_DIR/duration.awk"; }

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

check_deps() {
  local missing=() cmd
  for cmd in python3 mysql mysqldump jq curl awk sed gzip tar flock; do
    command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "missing required commands: ${missing[*]}"
  command -v Planimeter > /dev/null 2>&1 || warn "Planimeter (geographiclib-tools) not found: km2 of geofences will not be calculated"
}
