#!/usr/bin/env bash
# config.toml loading and validation.
#
# lib/toml2sh.py turns the TOML tables into flat bash variables: [database] host becomes
# $database_host, [retention] stats.rpl5 becomes $retention_stats_rpl5, arrays become bash
# arrays. Every key has a default below so a minimal config.toml works and `set -u` is safe.

config_defaults() {
  : "${database_host:=127.0.0.1}" "${database_port:=3306}" "${database_user:=}" "${database_password:=}"
  : "${database_dragonite:=dragonite}" "${database_golbat:=golbat}" "${database_stats:=stats}" "${database_koji:=koji}"
  : "${database_golbat_host:=}"

  : "${processing_worker_stats:=false}" "${processing_mon_area_stats:=false}" "${processing_quest_area_stats:=false}"
  : "${processing_account_stats:=false}" "${processing_fortwatcher:=false}"

  : "${geofences_use_koji:=false}" "${geofences_koji_project:=}"

  : "${dragonite_parse_log:=false}" "${dragonite_log_dir:=}"
  : "${dragonite_api_host:=127.0.0.1}" "${dragonite_api_port:=7272}"
  [[ -v dragonite_fort_areas ]] || dragonite_fort_areas=()
  : "${dragonite_invasion_worker:=}"

  : "${rotom_outage_report:=false}" "${rotom_discord_webhook:=}" "${rotom_api_host:=127.0.0.1}" "${rotom_api_port:=7072}"

  : "${backups_golbat:=false}" "${backups_golbat_days:=7}" "${backups_dragonite:=false}" "${backups_dragonite_days:=7}"

  local rpl key
  for rpl in 5 15 60 1440 10080; do
    for key in "retention_stats_rpl$rpl" "retention_dragonite_log_rpl$rpl"; do
      [[ -v $key ]] || printf -v "$key" '%s' 0
    done
  done
  : "${retention_accounts:=0}" "${retention_stats_account:=0}" "${retention_raw_workers:=0}" "${retention_raw_areas:=0}"

  : "${multi_instance_enabled:=false}" "${multi_instance_role:=master}" "${multi_instance_database:=allblissey}"
  : "${multi_instance_user:=}" "${multi_instance_password:=}"

  : "${koji_api_url:=}" "${koji_api_token:=}" "${koji_mon_project:=golbat}" "${koji_quest_project:=dragonite}"
}

load_config() {
  [[ -f "$BLISSEY_CONFIG" ]] || die "config not found: $BLISSEY_CONFIG (copy config.toml.example to config.toml, or convert an old config.ini with 'blissey migrate-config')"
  command -v python3 > /dev/null 2>&1 || die "python3 is required to read config.toml"
  local assignments
  assignments=$(python3 "$LIB_DIR/toml2sh.py" "$BLISSEY_CONFIG") || die "cannot read $BLISSEY_CONFIG"
  eval "$assignments"
  config_defaults
  validate_config
  mkdir -p "$LOG_DIR" "$TMP_DIR"
}

validate_config() {
  local key
  for key in database_user database_password database_host database_port database_stats database_golbat database_dragonite; do
    [[ -n "${!key}" ]] || die "config.toml: [database] ${key#database_} must be set"
  done
  for key in processing_worker_stats processing_mon_area_stats processing_quest_area_stats processing_account_stats \
             processing_fortwatcher geofences_use_koji dragonite_parse_log rotom_outage_report backups_golbat \
             backups_dragonite multi_instance_enabled; do
    case "${!key}" in
      true|false) ;;
      *) die "config.toml: $key must be true or false (got '${!key}')" ;;
    esac
  done
  for key in database_port dragonite_api_port rotom_api_port backups_golbat_days backups_dragonite_days \
             retention_stats_rpl5 retention_stats_rpl15 retention_stats_rpl60 retention_stats_rpl1440 retention_stats_rpl10080 \
             retention_dragonite_log_rpl5 retention_dragonite_log_rpl15 retention_dragonite_log_rpl60 \
             retention_dragonite_log_rpl1440 retention_dragonite_log_rpl10080 \
             retention_accounts retention_stats_account retention_raw_workers retention_raw_areas; do
    [[ "${!key}" =~ ^[0-9]+$ ]] || die "config.toml: $key must be a whole number (got '${!key}')"
  done
  if is_true "$geofences_use_koji" && [[ -z "$geofences_koji_project" ]]; then
    die "config.toml: [geofences] koji_project must be set when use_koji = true"
  fi
  if is_true "$dragonite_parse_log" && [[ -z "$dragonite_log_dir" ]]; then
    die "config.toml: [dragonite] log_dir must be set when parse_log = true"
  fi
  if is_true "$multi_instance_enabled"; then
    case "$multi_instance_role" in
      master|slave) ;;
      *) die "config.toml: [multi_instance] role must be master or slave (got '$multi_instance_role')" ;;
    esac
    [[ -n "$multi_instance_database" ]] || die "config.toml: [multi_instance] database must be set when enabled = true"
    : "${multi_instance_user:=$database_user}" "${multi_instance_password:=$database_password}"
  fi
}

is_multi()        { is_true "$multi_instance_enabled"; }
is_multi_master() { is_true "$multi_instance_enabled" && [[ "$multi_instance_role" == "master" ]]; }
has_fort_areas()  { (( ${#dragonite_fort_areas[@]} > 0 )); }

# fort_areas_sql — the fort areas as a SQL list: 'fortsRoute1','fortsRoute2'
fort_areas_sql() {
  local area list=""
  for area in "${dragonite_fort_areas[@]}"; do
    list+="${list:+,}'$area'"
  done
  echo "$list"
}

# ---------------------------------------------------------------------------
# migrate-config: print a config.toml equivalent to an old config.ini
# ---------------------------------------------------------------------------

migrate_config_ini() {
  local ini=$1
  [[ -f "$ini" ]] || die "not found: $ini"
  # subshell: the ini defines plain variables that must not leak into the caller
  (
    set +u
    # shellcheck source=/dev/null
    source "$ini"
    ini_to_toml
  )
}

toml_str()  { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
toml_bool() { if [[ "$1" == "true" ]]; then echo true; else echo false; fi; }
toml_int()  { if [[ "$1" =~ ^[0-9]+$ ]]; then echo "$1"; else echo "${2:-0}"; fi; }
toml_list() {
  local item list=""
  for item in $1; do list+="${list:+, }$(toml_str "$item")"; done
  echo "[$list]"
}

ini_to_toml() {
  cat <<EOF
# Generated by 'blissey migrate-config' from an old config.ini. Review before use.

[database]
host = $(toml_str "${dbip:-127.0.0.1}")
port = $(toml_int "${dbport:-3306}" 3306)
user = $(toml_str "${sqluser:-}")
password = $(toml_str "${sqlpass:-}")
dragonite = $(toml_str "${dragonitedb:-${controllerdb:-dragonite}}")
golbat = $(toml_str "${scannerdb:-golbat}")
stats = $(toml_str "${blisseydb:-stats}")
koji = $(toml_str "${kojidb:-koji}")
golbat_host = $(toml_str "${golbat_host:-}")

[processing]
worker_stats = $(toml_bool "${workerstats:-false}")
mon_area_stats = $(toml_bool "${monareastats:-false}")
quest_area_stats = $(toml_bool "${questareastats:-false}")
account_stats = $(toml_bool "${dragoaccount:-false}")
fortwatcher = $(toml_bool "${fortwatcher:-false}")

[geofences]
use_koji = $(toml_bool "${use_koji:-false}")
koji_project = $(toml_str "${project_controller:-}")

[dragonite]
parse_log = $(toml_bool "${dragonitelog:-false}")
log_dir = $(toml_str "${dragonite_path:+${dragonite_path}/logs}")
api_host = $(toml_str "${dragonite_api_host:-127.0.0.1}")
api_port = $(toml_int "${dragonite_api_port:-7272}" 7272)
fort_areas = $(toml_list "${fort_area_name:-}")
invasion_worker = $(toml_str "${invasion_worker_name:-}")

[rotom]
outage_report = $(toml_bool "${outage_report:-false}")
discord_webhook = $(toml_str "${outage_webhook:-}")
api_host = $(toml_str "${rotom_api_host:-127.0.0.1}")
api_port = $(toml_int "${rotom_api_port:-7072}" 7072)

[backups]
golbat = $(toml_bool "${golbat_backup:-false}")
golbat_days = $(toml_int "${golbat_backup_days:-7}" 7)
dragonite = $(toml_bool "${drago_backup:-false}")
dragonite_days = $(toml_int "${drago_backup_days:-7}" 7)

[retention]
stats         = { rpl5 = $(toml_int "${blissey_rpl5:-0}"), rpl15 = $(toml_int "${blissey_rpl15:-0}"), rpl60 = $(toml_int "${blissey_rpl60:-0}"), rpl1440 = $(toml_int "${blissey_rpl1440:-0}"), rpl10080 = $(toml_int "${blissey_rpl10080:-0}") }
dragonite_log = { rpl5 = $(toml_int "${d2log_rpl5:-0}"), rpl15 = $(toml_int "${d2log_rpl15:-0}"), rpl60 = $(toml_int "${d2log_rpl60:-0}"), rpl1440 = $(toml_int "${d2log_rpl1440:-0}"), rpl10080 = $(toml_int "${d2log_rpl10080:-0}") }
accounts = $(toml_int "${accounts_rpl15:-0}")
stats_account = $(toml_int "${account_stats:-0}")
raw_workers = $(toml_int "${worker_raw:-0}")
raw_areas = $(toml_int "${area_raw:-0}")

[multi_instance]
enabled = $(toml_bool "${multiblissey:-false}")
role = $(toml_str "${multiblisseyrole:-master}")
database = $(toml_str "${multiblisseydb:-allblissey}")
user = $(toml_str "${multisqluser:-}")
password = $(toml_str "${multisqlpass:-}")

[koji]
api_url = ""
api_token = ""
mon_project = "golbat"
quest_project = "dragonite"
EOF
}
