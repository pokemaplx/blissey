#!/usr/bin/env bash
# dragonite.log parsing (rpl 5). Every 5 minutes the log lines of the previous 5 minutes are
# copied to data/tmp/d2_interval.log and counted into dragoLog, dragoLog_fort,
# dragoLog_invasion, stats_worker_fort, stats_prioraid and stats_invasion.
#
# Three worker classes are counted separately:
#   generic   everything that is not one of the two below
#   fort      workers of the fort areas      "[<dragonite.fort_areas>_...]"
#   invasion  the invasion worker            "[<invasion_worker_name>_...]"

SLICE=""          # log slice being processed
BUCKET_EPOCH=""   # start of the 5 minute bucket being processed (unix time)
PROCESS_TIME=""   # the same as "YYYY-MM-DD HH:MM:00"
INV_PAT=""        # grep (BRE) pattern for invasion worker lines
FORT_PAT=""       # grep (BRE) pattern for fort worker lines
NO_MATCH='\[blissey-nomatch_'   # pattern that never matches a worker tag

# column=pattern pairs; every class gets its own count of these
RPC_METRICS=(
  "rpc4=RPC Status 4 received"   "rpc5=RPC Status 5 received"   "rpc6=RPC Status 6 received"
  "rpc7=RPC Status 7 received"   "rpc8=RPC Status 8 received"   "rpc9=RPC Status 9 received"
  "rpc11=RPC Status 11 received" "rpc12=RPC Status 12 received" "rpc13=RPC Status 13 received"
  "rpc14=RPC Status 14 received" "rpc15=RPC Status 15 received" "rpc16=RPC Status 16 received"
  "rpc17=RPC Status 17 received" "rpc18=RPC Status 18 received"
)
# account switches by reason (swBanned is computed separately, see count_banned)
SWITCH_METRICS=(
  "swTotal=Final request counts"
  "swWarnSusp=Account .* marked as suspended"
  "swSbanned=Account .* marked as shadow banned"
  "swDisabled=Account .* marked as disabled"
  "swDayLimit=Exceeded daily limit. New account needed"
  "swRange=Got out of range 10 times. Possibly exceeded daily limit. New account needed"
  "swTime=Maximum connection time exceeded"
  "swStop=Pokestop is in cooldown, new account needed"
  "swLLapi=requires recycle, reason: Low level api"
  "swQdist=Long distance jump in questing"
  "swConsecRPC=requires recycle, reason: Too many consecutive rpc errors"
  "backoff=BACKOFF: Error logging into Pogo\|BACKOFF: New account attempt"
)
# counted over the whole log regardless of worker
GLOBAL_METRICS=(
  "mitm500=ERROR_UNKNOWN"
  "mitm501=ERROR_RETRY_LATER"
  "mitm502=ERROR_WORKER_STOPPED"
  "mitm503=ERROR_RECONNECT"
  "mitmLoginErr=Login for user.*error"
  "proxyBan=PTC Ban Detected on proxy"
  "wsError=WS Error"
  "wsClose=WS Has been closed"
  "wsMitmRecon=received from Mitm.*triggering reconnect"
  "authReq=Requested auth"
  "authed=Authenticated user"
  "login=Login for user.*to device.*successful"
  "noAccount=No accounts available to authenticate"
  "released24h=which is less than 24 hours ago. This is probably not what you want"
  "released7d=which is less than 1 week ago. This is probably not what you want"
  "monchange=Encounter.*pokemon changed"
  "totRemoteAuth=Remote Auth for.*took"
  "failRemoteAuth=Remote Auth for.*- Error from remote auth\|Remote Auth for.*- Empty code received"
  "faultyRemoteAuth=Remote Auth for.*- Error authenticating with remote auth details"
  "bgRefreshSuc=Background refresh for.*succeeded"
  "bgRefreshFail=Background refresh for.*failed"
  "bTokenReq=Background token initer: Trying to authenticate"
  "bTokenSuc=Background token initer: Stored token for user"
  "tokenCleared=token cleared"
)

dragolog_run() {
  SLICE="$TMP_DIR/d2_interval.log"
  # previous bucket, floored to 5 minutes like the SQL side does — stays correct when a tick
  # starts late (e.g. after waiting for the previous one)
  BUCKET_EPOCH=$(( ($(date +%s) - 300) / 300 * 300 ))
  PROCESS_TIME=$(date -d "@$BUCKET_EPOCH" '+%Y-%m-%d %H:%M:00')
  INV_PAT="\[${dragonite_invasion_worker:-blissey-nomatch}_"
  FORT_PAT=$(fort_pattern)
  rm -f "$SLICE"

  timed "rpl5 drago log processing" dragolog_counts
  if [[ -f "$SLICE" ]]; then
    has_fort_areas                   && timed "rpl5 fort log processing" dragolog_forts
    [[ -n "$dragonite_invasion_worker" ]] && timed "rpl5 invasion processing" dragolog_invasion
  fi
  rm -f "$SLICE"
  return 0
}

# "\[area1_\|\[area2_" for fort_areas = ["area1", "area2"]
fort_pattern() {
  has_fort_areas || { echo "$NO_MATCH"; return; }
  local area pattern=""
  for area in "${dragonite_fort_areas[@]}"; do
    pattern+="${pattern:+\\|}\\[${area}_"
  done
  echo "$pattern"
}

# ---------------------------------------------------------------------------
# Slice extraction
# ---------------------------------------------------------------------------

# Copy the lines whose timestamp (3rd field) falls in the bucket's 5 minutes to $SLICE.
dragolog_extract() {
  local dlog="$dragonite_log_dir/dragonite.log" filter="" i
  if [[ ! -f "$dlog" ]]; then
    log "No dragonite logfile found to process ($dlog)"
    return 1
  fi
  for i in 0 1 2 3 4; do
    filter+="${filter:+ || }\$3 ~ /$(date -d "@$((BUCKET_EPOCH + i * 60))" +%H:%M:)/"
  done
  if [[ $(date -d "@$BUCKET_EPOCH" +%M) == 55 ]]; then
    # Dragonite rotated its log at the top of the hour; the bucket's lines now live in
    # dragonite-<rotation time>*.log(.gz). Give the compression a moment to finish.
    sleep 30
    zcat -f "$dragonite_log_dir"/dragonite-"$(date -d "@$((BUCKET_EPOCH + 300))" +%Y-%m-%dT%H)"* | awk "$filter" > "$SLICE"
  else
    awk "$filter" "$dlog" > "$SLICE"
  fi
}

# ---------------------------------------------------------------------------
# Counting helpers
# ---------------------------------------------------------------------------

# class_lines <all|generic|fort|invasion> — the slice lines of one worker class
class_lines() {
  case "$1" in
    all)      cat "$SLICE" ;;
    generic)  grep -v -- "$INV_PAT" "$SLICE" | grep -v -- "$FORT_PAT" ;;
    fort)     grep -- "$FORT_PAT" "$SLICE" ;;
    invasion) grep -- "$INV_PAT" "$SLICE" ;;
  esac
}

# count <class> <pattern> — number of lines of the class matching the pattern
count() { class_lines "$1" | grep -c -- "$2"; }

# Banned accounts: either the explicit "marked as banned" switches or, when Dragonite only
# logged BANNED ACCOUNT lines, the number of distinct workers that hit one — whichever is higher.
count_banned() {
  local marked distinct
  marked=$(class_lines "$1" | grep -- 'Account .* marked as banned' | grep -vc 'but AR Task received')
  distinct=$(class_lines "$1" | grep -- 'BANNED ACCOUNT' | awk '{ print $4 }' | sort -u | wc -l)
  echo $(( marked > distinct ? marked : distinct ))
}

# build_counts <class> <column=pattern>... — sets COLS / VALS (comma separated)
build_counts() {
  local class=$1 metric name pattern; shift
  COLS=""; VALS=""
  for metric in "$@"; do
    name=${metric%%=*}; pattern=${metric#*=}
    COLS+="${COLS:+,}$name"
    VALS+="${VALS:+,}$(count "$class" "$pattern")"
  done
}

# build_class_counts <class> — RPC status + account switch counters of one worker class
build_class_counts() {
  build_counts "$1" "${RPC_METRICS[@]}" "${SWITCH_METRICS[@]}"
  COLS+=",swBanned"
  VALS+=",$(count_banned "$1")"
}

# field_after <prefix> <text> — the digits following <prefix> in <text>, or 0
field_after() {
  if [[ $2 =~ $1([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; else echo 0; fi
}

# min_max_avg <values> — "<min>,<max>,<avg>" of the numbers (one per line) in <values>
min_max_avg() {
  echo "$(agg min <<< "$1"),$(agg max <<< "$1"),$(agg avg <<< "$1")"
}

# ---------------------------------------------------------------------------
# dragoLog / dragoLog_fort / dragoLog_invasion
# ---------------------------------------------------------------------------

dragolog_counts() {
  dragolog_extract || return 0
  local cols vals auth remote token

  build_class_counts generic
  cols=$COLS; vals=$VALS
  build_counts all "${GLOBAL_METRICS[@]}"
  cols+=",$COLS"; vals+=",$VALS"
  auth=$(grep 'Authenticated user' "$SLICE" | awk '{ print $10 }' | tr -d ')' | durations_ms)
  remote=$(grep 'Remote Auth for.*took' "$SLICE" | awk '{ print $NF }' | tr -d '[]' | durations_ms)
  token=$(grep 'Background token initer: Stored token for user' "$SLICE" | awk '{ print $NF }' | tr -d ')' | durations_ms)
  cols+=",minAuthT,maxAuthT,avgAuthT,minRemoteAuthT,maxRemoteAuthT,avgRemoteAuthT,bTokenMin,bTokenMax,bTokenAvg"
  vals+=",$(min_max_avg "$auth"),$(min_max_avg "$remote"),$(min_max_avg "$token")"
  mysql_blissey -e "insert ignore into dragoLog (datetime,rpl,$cols) values ('$PROCESS_TIME',5,$vals);"
  update_low_duration dragoLog "mode in ('PokemonMode','QuestMode')"

  if has_fort_areas; then
    build_class_counts fort
    mysql_blissey -e "insert ignore into dragoLog_fort (datetime,rpl,$COLS) values ('$PROCESS_TIME',5,$VALS);"
    update_low_duration dragoLog_fort "mode = 'FortMode'"
  fi
  if [[ -n "$dragonite_invasion_worker" ]]; then
    build_class_counts invasion
    mysql_blissey -e "insert ignore into dragoLog_invasion (datetime,rpl,$COLS) values ('$PROCESS_TIME',5,$VALS);"
    update_low_duration dragoLog_invasion "mode = 'InvasionMode'"
  fi
}

# update_low_duration <table> <mode condition> — sessions shorter than 20s in this bucket,
# read from Dragonite's own session table (skipped on Dragonite versions without it).
update_low_duration() {
  local table=$1 condition=$2
  [[ "${HAS_STATS_ACCOUNTS:-}" ]] || HAS_STATS_ACCOUNTS=$(mysql_dragonite -NB -e "show tables like 'stats_accounts';" | grep -c . || true)
  [[ "$HAS_STATS_ACCOUNTS" == 1 ]] || return 0
  mysql_blissey -e "update $table set lowDuration = (select count(*) from ${database_dragonite}.stats_accounts where session_end > '$PROCESS_TIME' and duration_ms < 20000 and $condition) where datetime = '$PROCESS_TIME' and rpl = 5;"
}

# ---------------------------------------------------------------------------
# stats_worker_fort / stats_prioraid — fort mode workers and priority raid scanning
# ---------------------------------------------------------------------------

dragolog_forts() {
  local worker name fetchRaid modeLocations fortLookup protoFort protoRaid

  while read -r worker; do
    name=${worker//[\[\]]/}
    fetchRaid=$(grep -F -- "$worker" "$SLICE" | grep -c 'Fetching raids around')
    modeLocations=$(grep -F -- "$worker" "$SLICE" | grep -c 'Moving to')
    fortLookup=$(grep -F -- "$worker" "$SLICE" | grep 'Waiting for .* fort lookups to complet' | awk '{ print $7 }' | agg sum)
    protoFort=$(grep -F -- "$worker" "$SLICE" | grep 'location time elapsed' | grep -v 'RAIDWATCHER' | awk '{ print $10 }' | durations_ms | agg sum)
    protoRaid=$(grep -F -- "$worker" "$SLICE" | grep 'location time elapsed' | grep 'RAIDWATCHER' | awk '{ print $9 }' | durations_ms | agg sum)
    mysql_blissey -e "insert ignore into stats_worker_fort (datetime,rpl,worker,fetchRaid,modeLocations,fortLookup,totalProtoTimeFort,totalProtoTimeRaid) values ('$PROCESS_TIME',5,'$name',$fetchRaid,$modeLocations,$fortLookup,$protoFort,$protoRaid);"
  done < <(grep -- "$FORT_PAT" "$SLICE" | awk '{ print $4 }' | sort -u)

  local popped='RAIDWATCHER:.*Raid at gym.*pokemon discovered egg popped' queued='RAIDWATCHER:.*raids in queue'
  local scanCount scan raid Qcount active queue
  scanCount=$(count all "$popped")
  scan=$(grep "$popped" "$SLICE" | awk '{ print $19 }' | tr -d '[]' | durations_ms)
  raid=$(grep "$popped" "$SLICE" | awk '{ print $26 }' | tr -d '[]' | durations_ms)
  Qcount=$(count all "$queued")
  active=$(grep "$queued" "$SLICE" | awk '{ print $11 }' | tr -d '[')
  queue=$(grep "$queued" "$SLICE" | awk '{ print $7 }')
  mysql_blissey -e "insert ignore into stats_prioraid (datetime,rpl,scanCount,scanMin,scanMax,scanAvg,raidMin,raidMax,raidAvg,raidActiveMin,raidActiveMax,raidActiveAvg,raidQueueMin,raidQueueMax,raidQueueAvg,Qcount) values ('$PROCESS_TIME',5,$scanCount,$(min_max_avg "$scan"),$(min_max_avg "$raid"),$(min_max_avg "$active"),$(min_max_avg "$queue"),$Qcount);"
}

# ---------------------------------------------------------------------------
# stats_invasion
# ---------------------------------------------------------------------------

# counter_delta <label> <first line> <last line> — growth of "<label>: N" between two lines
# (Dragonite resets the counters on account switch, then the last value is what was done)
counter_delta() {
  local first last
  first=$(field_after "$1: " "$2")
  last=$(field_after "$1: " "$3")
  if (( first <= last )); then echo $(( last - first )); else echo "$last"; fi
}

dragolog_invasion() {
  local workers avgTime detect failed finished expired queue grunt leader
  local worker first last grunts=0 leaders=0 giovanni=0 giovanniLineups=0

  workers=$(class_lines invasion | awk '{ print $4 }' | sort -u | wc -l)
  avgTime=$(class_lines invasion | grep 'Done with invasion' | grep -oP '(?<=Took: ).*(?= \| Time left)' | durations_ms | agg avg)
  detect=$(count all 'Detecting lineup for Invasion')
  failed=$(count all 'failed to detect lineup for invasion')
  finished=$(count all 'Done with invasion')
  expired=$(count all 'Invasion .* expired')
  queue=$(grep 'invasions in queue' "$SLICE" | awk '{ print $6 }')
  # shellcheck disable=SC2016  # the backticks are part of the log line
  grunt=$(grep 'Done with invasion .* of type `grunt`' "$SLICE" | grep -oP '(?<=Time left before despawn: )\S+' | durations_min)
  # shellcheck disable=SC2016
  leader=$(grep 'Done with invasion .* of type `leader`' "$SLICE" | grep -oP '(?<=Time left before despawn: )\S+' | durations_min)

  # line-ups per worker: difference between the first and the last "Done with invasion" line
  while read -r worker; do
    first=$(grep -F -- "$worker" "$SLICE" | grep 'Done with invasion' | head -1)
    last=$(grep -F -- "$worker" "$SLICE" | grep 'Done with invasion' | tail -1)
    if [[ -z "$first" ]]; then
      log "[$(now)] Invasion worker $worker did not finish any invasion in this interval"
      continue
    fi
    grunts=$((          grunts          + $(counter_delta "Grunts line-ups"    "$first" "$last") ))
    leaders=$((         leaders         + $(counter_delta "Leaders line-ups"   "$first" "$last") ))
    giovanni=$((        giovanni        + $(counter_delta "Giovanni confirmed" "$first" "$last") ))
    giovanniLineups=$(( giovanniLineups + $(counter_delta "Giovanni line-ups"  "$first" "$last") ))
  done < <(class_lines invasion | awk '{ print $4 }' | sort -u)

  mysql_blissey -e "insert ignore into stats_invasion (datetime,rpl,workers,avgTime,detect,failed,done,expired,qmin,qmax,qavg,grLine,leLine,giConf,giLine,gmin,gmax,gavg,lmin,lmax,lavg) values ('$PROCESS_TIME',5,$workers,$avgTime,$detect,$failed,$finished,$expired,$(min_max_avg "$queue"),$grunts,$leaders,$giovanni,$giovanniLineups,$(min_max_avg "$grunt"),$(min_max_avg "$leader"));"
}
