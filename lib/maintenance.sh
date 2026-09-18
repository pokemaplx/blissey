#!/usr/bin/env bash
# Housekeeping: daily backups, data retention, Dragonite log rotation request, log header.

# Everything that runs once a day after the rpl 1440 aggregation.
maintenance_daily() {
  if is_true "$backups_golbat"; then
    timed "daily golbat backup" backup_golbat
    timed "daily golbat backup cleanup" prune_backups "$BACKUP_DIR/golbat" "$backups_golbat_days"
  fi
  if is_true "$backups_dragonite"; then
    timed "daily dragonite backup" backup_dragonite
    timed "daily dragonite backup cleanup" prune_backups "$BACKUP_DIR/dragonite" "$backups_dragonite_days"
  fi
  retention_cleanup blissey
  if is_multi_master; then
    retention_cleanup multi
  fi
}

# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------

# Golbat: full structure + routines, data only for the slowly changing tables.
backup_golbat() {
  local dir="$BACKUP_DIR/golbat" file
  file="golbatbackup_$(date +%Y-%m-%d).sql"
  mkdir -p "$dir"
  mysqldump_scanner --no-data --routines "$database_golbat" > "$dir/$file" || return 1
  mysqldump_scanner "$database_golbat" gym pokestop spawnpoint schema_migrations >> "$dir/$file" || return 1
  compress_backup "$dir" "$file"
}

backup_dragonite() {
  local dir="$BACKUP_DIR/dragonite" file
  file="dragobackup_$(date +%Y-%m-%d).sql"
  mkdir -p "$dir"
  mysqldump_dragonite "$database_dragonite" > "$dir/$file" || return 1
  compress_backup "$dir" "$file"
}

compress_backup() {
  local dir=$1 file=$2
  [[ "${BLISSEY_DRY_RUN:-0}" == 1 ]] && { rm -f "$dir/$file"; return 0; }
  tar --remove-files -czf "$dir/$file.tar.gz" -C "$dir" "$file"
}

# prune_backups <dir> <days>
prune_backups() {
  [[ -d "$1" ]] || return 0
  find "$1" -type f -mtime +"$2" -exec rm -f {} \;
}

# ---------------------------------------------------------------------------
# Retention
# ---------------------------------------------------------------------------

# purge_rpl_table <target> <table> <days rpl5> <days rpl15> <days rpl60> <days rpl1440> <days rpl10080>
# 0 days keeps that interval forever.
purge_rpl_table() {
  local target=$1 table=$2 rpl days; shift 2
  for rpl in 5 15 60 1440 10080; do
    days=$1; shift
    (( days > 0 )) || continue
    "mysql_$target" -e "delete from $table where rpl = $rpl and datetime < now() - interval $days day;"
  done
}

# retention_cleanup [blissey|multi] — apply the [retention] settings (days, 0 = forever) to a database
retention_cleanup() {
  local target=${1:-blissey} label=""
  [[ "$target" == multi ]] && label=" (combined blissey db)"
  local stats=("$retention_stats_rpl5" "$retention_stats_rpl15" "$retention_stats_rpl60" "$retention_stats_rpl1440" "$retention_stats_rpl10080")
  local d2log=("$retention_dragonite_log_rpl5" "$retention_dragonite_log_rpl15" "$retention_dragonite_log_rpl60" "$retention_dragonite_log_rpl1440" "$retention_dragonite_log_rpl10080")

  if (( retention_stats_rpl5 + retention_stats_rpl15 + retention_stats_rpl60 + retention_stats_rpl1440 + retention_stats_rpl10080 > 0 )); then
    timed "cleanup stats tables$label" purge_stats_tables "$target" "${stats[@]}"
  fi
  if (( retention_accounts > 0 )); then
    timed "cleanup table accounts$label" \
      "mysql_$target" -e "delete from accounts where rpl = 15 and datetime < now() - interval $retention_accounts day;"
  fi
  if (( retention_stats_account > 0 )); then
    timed "cleanup table stats_account$label" \
      "mysql_$target" -e "delete from stats_account where datetime < now() - interval $retention_stats_account day;"
  fi
  if (( retention_dragonite_log_rpl5 + retention_dragonite_log_rpl15 + retention_dragonite_log_rpl60 + retention_dragonite_log_rpl1440 + retention_dragonite_log_rpl10080 > 0 )); then
    timed "cleanup tables dragoLog and stats_invasion$label" purge_dragolog_tables "$target" "${d2log[@]}"
  fi
}

purge_stats_tables() {
  local target=$1; shift
  if is_true "$processing_worker_stats"; then
    purge_rpl_table "$target" stats_worker "$@" || return 1
  fi
  purge_rpl_table "$target" stats_mon_area "$@" || return 1
  purge_rpl_table "$target" stats_quest_area "$@"
}

purge_dragolog_tables() {
  local target=$1 table; shift
  for table in dragoLog dragoLog_invasion dragoLog_fort stats_invasion stats_worker_fort stats_prioraid; do
    purge_rpl_table "$target" "$table" "$@" || return 1
  done
}

# ---------------------------------------------------------------------------
# Dragonite
# ---------------------------------------------------------------------------

# Ask Dragonite to rotate dragonite.log (hourly). Newer versions answer 202 on /logrotate,
# older ones expose /log-rotate.
request_logrotate() {
  local base="http://$dragonite_api_host:$dragonite_api_port" code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$base/logrotate")
  if [[ "$code" != 202 ]]; then
    curl -s -k -L --fail --show-error "$base/log-rotate"
  fi
}

# ---------------------------------------------------------------------------
# Log file
# ---------------------------------------------------------------------------

log_day_header() {
  log " "
  log "#########################          $(date '+%Y-%m-%d')           #########################"
  log "Start time          Stop time           Duration  Process"
}
