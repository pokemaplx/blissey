#!/usr/bin/env bash
# Interval processing ("rpl" = reporting period length in minutes: 5, 15, 60, 1440, 10080).
#
# Every interval except 5 is a plain aggregation of the next smaller interval and is fully
# described by the files in sql/rpl/<rpl>/. Interval 5 reads the raw Dragonite/Golbat data
# and has a few special cases (Golbat on another server, dragonite.log parsing).

RPL_STEPS=(worker mon_area quest_area fortwatcher drago_account dragonite fort invasion)

# run_interval <rpl>
run_interval() {
  local rpl=$1 step
  case "$rpl" in
    5) run_interval_5; return ;;
    15|60|1440|10080) ;;
    *) die "unknown interval '$rpl' (expected 5, 15, 60, 1440 or 10080)" ;;
  esac
  for step in "${RPL_STEPS[@]}"; do
    run_step "$rpl" "$step"
  done
  if [[ "$rpl" == 15 ]] && is_multi && step_enabled drago_account; then
    timed "rpl15 accounts to combined blissey db" multi_run_files 15 drago_account
  fi
  multi_aggregate "$rpl"
  if [[ "$rpl" == 1440 ]]; then
    maintenance_daily
  fi
}

# run_step <rpl> <step> — run sql/rpl/<rpl>/<step>.sql when the step is enabled in config.toml
run_step() {
  local rpl=$1 step=$2 file="$SQL_DIR/rpl/$1/$2.sql"
  step_enabled "$step" || return 0
  [[ -f "$file" ]] || return 0
  timed "rpl$rpl $(step_label "$step")" sql_run blissey "$file"
}

step_enabled() {
  case "$1" in
    worker)                  is_true "$processing_worker_stats" ;;
    mon_area)                is_true "$processing_mon_area_stats" ;;
    quest_area)              is_true "$processing_quest_area_stats" ;;
    fortwatcher)             is_true "$processing_fortwatcher" ;;
    drago_account)           is_true "$processing_account_stats" ;;
    dragonite|fort|invasion) is_true "$dragonite_parse_log" ;;
    *) return 1 ;;
  esac
}

step_label() {
  case "$1" in
    worker)        echo "worker stats" ;;
    mon_area)      echo "mon area stats" ;;
    quest_area)    echo "quest area stats" ;;
    fortwatcher)   echo "fortwatcher stats" ;;
    drago_account) echo "drago account stats" ;;
    dragonite)     echo "drago log" ;;
    fort)          echo "fort log" ;;
    invasion)      echo "invasion" ;;
  esac
}

# ---------------------------------------------------------------------------
# rpl 5
# ---------------------------------------------------------------------------

run_interval_5() {
  is_true "$processing_worker_stats"    && timed "rpl5 worker stats" sql_run blissey "$SQL_DIR/rpl/5/worker.sql"
  is_true "$processing_mon_area_stats"   && timed "rpl5 mon area stats" rpl5_mon_area
  is_true "$processing_quest_area_stats" && timed "rpl5 quest area stats" rpl5_quest_area
  report_outages
  is_true "$dragonite_parse_log"   && dragolog_run
  multi_copy_5
  cleanup_raw_tables
  return 0
}

# Start of the 5-minute bucket being processed, as seen by the stats database.
rpl5_period() {
  mysql_blissey -NB -e "select concat(date(now() - interval 5 minute), ' ', sec_to_time((time_to_sec(time(now() - interval 5 minute)) div 300) * 300));"
}

# rows_to_insert <table> <columns> <rows> — rows are "(...)," lines produced by the
# external-Golbat queries; the scanner-side timestamp is replaced by the stats-side one so
# the two servers do not need synchronised clocks.
rows_to_insert() {
  local table=$1 columns=$2 rows=$3 period
  period=$(rpl5_period)
  rows=$(echo "$rows" | grep "^('2" | sed "s/^(.*',5,'/('$period',5,'/")
  [[ -n "$rows" ]] || return 0
  printf 'insert ignore into %s (%s) values\n%s;\n' "$table" "$columns" "${rows%,}" | mysql_blissey
}

rpl5_mon_area() {
  if [[ -z "$database_golbat_host" ]]; then
    sql_run blissey "$SQL_DIR/rpl/5/mon_area.sql"
    return
  fi
  local rows
  rows=$(sql_run scanner "$SQL_DIR/rpl/5/mon_area_external.sql" -NB)
  rows_to_insert stats_mon_area \
    "datetime,rpl,area,fence,totMon,ivMon,verifiedEnc,unverifiedEnc,verifiedReEnc,encSecLeft,encTthMax5,encTth5to10,encTth10to15,encTth15to20,encTth20to25,encTth25to30,encTth30to35,encTth35to40,encTth40to45,encTth45to50,encTth50to55,encTthMin55,resetMon,re_encSecLeft,numWiEnc,secWiEnc" \
    "$rows"
}

rpl5_quest_area() {
  local isolation="SET SESSION TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;"
  if [[ -z "$database_golbat_host" ]]; then
    mysql_blissey -NB -e "$isolation call rpl5questarea();"
    return
  fi
  local rows fences="$TMP_DIR/questfences.txt"
  if is_true "$geofences_use_koji"; then
    rows=$(mysql_scanner -NB -e "$isolation call rpl5questarea();")
  else
    # Without Koji the scanner server has no fence table: ship the quest fences over as a
    # temporary table before calling the procedure.
    mysql_blissey -NB -e "set @row_number = 0; select concat((@row_number := @row_number + 1), '|', area, '|', fence, '|', st_astext(st_lonlat)) from geofences where st_lonlat is not null and (type = 'quest' or type = 'both');" > "$fences"
    rows=$(mysql_scanner -NB --local-infile=1 -e "$isolation create temporary table areas (id int not null, area varchar(40) not null, fence varchar(40) not null, coords text not null) engine=InnoDB default charset=utf8mb4 collate=utf8mb4_unicode_ci; load data local infile '$fences' into table areas fields terminated by '|'; call rpl5questarea();")
  fi
  rows_to_insert stats_quest_area "datetime,rpl,area,fence,stops,AR,nonAR,ARcum,nonARcum" "$rows"
}

# Post a Discord message listing devices that stopped sending data (Rotom API).
report_outages() {
  is_true "$rotom_outage_report" && [[ -n "$rotom_discord_webhook" ]] || return 0
  local outages description
  # tab separated so device names containing spaces survive
  outages=$(curl -s "$rotom_api_host:$rotom_api_port/api/status" \
    | jq -r '.devices[] | [.origin, (.dateLastMessageReceived | tostring)] | @tsv' \
    | awk -F '\t' '{ if ($2 <= systime() * 1000 - 180000) print $1, strftime("%Y%m%d_%H:%M:%S", $2 / 1000) }')
  [[ -n "$outages" ]] || return 0
  # discord.sh pastes the description straight into JSON, so escape it as a JSON string body
  description=$(printf '%s' "$outages" | jq -Rs .)
  description=${description:1:-1}
  "$TOOLS_DIR/discord.sh" --username "Containers, no update in 3m" --color "16711680" \
    --avatar "https://www.iconsdb.com/icons/preview/red/exclamation-xxl.png" \
    --webhook-url "$rotom_discord_webhook" --description "$description"
}

# Raw source tables only need to keep a day or so; the aggregated data lives in the stats db.
cleanup_raw_tables() {
  if (( retention_raw_areas > 0 )); then
    timed "cleanup golbat table pokemon_area_stats" \
      mysql_scanner -e "delete from pokemon_area_stats where datetime < unix_timestamp(now() - interval $retention_raw_areas day);"
  fi
  if (( retention_raw_workers > 0 )) && is_true "$processing_worker_stats"; then
    timed "cleanup dragonite table stats_workers" \
      mysql_dragonite -e "delete from stats_workers where datetime < utc_timestamp() - interval $retention_raw_workers day;"
  fi
}

# ---------------------------------------------------------------------------
# Multi-instance: every Blissey instance sums its rpl 5 rows into one central database
# (config [multi_instance], SQL in sql/multi/); the master instance additionally rolls that
# database up to the larger intervals with the regular aggregation files.
# ---------------------------------------------------------------------------

multi_copy_5() {
  is_multi || return 0
  sleep 10   # let the other instances finish their rpl 5 inserts first
  timed "rpl5 processing to combined blissey db" multi_run_files 5 mon_area quest_area worker dragonite fort
}

# multi_aggregate <rpl> — master only, for 15/60/1440/10080
multi_aggregate() {
  local rpl=$1
  is_multi_master || return 0
  sleep 10
  timed "rpl$rpl processing to combined blissey db" multi_run_files "$rpl" mon_area quest_area worker dragonite fort
}

# multi_run_files <rpl> <step>... — run sql/multi/<rpl>/<step>.sql (or, when there is no
# multi-specific variant, sql/rpl/<rpl>/<step>.sql) against the central database
multi_run_files() {
  local rpl=$1 step file; shift
  for step in "$@"; do
    step_enabled "$step" || continue
    file="$SQL_DIR/multi/$rpl/$step.sql"
    [[ -f "$file" ]] || file="$SQL_DIR/rpl/$rpl/$step.sql"
    [[ -f "$file" ]] || continue
    sql_run multi "$file" || return 1
  done
}
