#!/usr/bin/env bash
# Database setup: schema, migrations and stored procedures. Idempotent — safe to run on
# every start (the Docker entrypoint does).

setup_all() {
  log "[$(now)] setup executed"
  setup_schema blissey "$database_stats"
  setup_migrations blissey
  if is_multi_master; then
    # the master instance owns the central database of a multi-instance setup
    setup_schema multi "$multi_instance_database"
    setup_migrations multi
  fi
  setup_procedures
  echo "Setup done."
}

# setup_schema <blissey|multi> <database name>
setup_schema() {
  echo "Creating tables in '$2'"
  sql_run "$1" "$SQL_DIR/schema.sql"
}

# setup_migrations <blissey|multi> — apply sql/migrations/<n>.sql for every n greater than
# the version stored in table `version` of that database.
setup_migrations() {
  local target=$1 version file number
  echo "Checking for migrations ($target)"
  version=$("mysql_$target" -NB -e "select version from version where version.key='blissey'")
  [[ "$version" =~ ^[0-9]+$ ]] || version=0
  echo "  current version: $version"
  while read -r number; do
    file="$SQL_DIR/migrations/$number.sql"
    if (( number > version )); then
      echo "  applying migration $number"
      sql_run "$target" "$file" || die "migration $number failed"
    fi
  done < <(for f in "$SQL_DIR"/migrations/*.sql; do basename "$f" .sql; done | sort -n)
}

# The quest-area procedure lives in the stats db, or in the scanner db when Golbat runs on
# another server (the procedure has to join golbat.pokestop locally).
setup_procedures() {
  local file target
  if [[ -z "$database_golbat_host" ]]; then
    file="$SQL_DIR/procedures/quest_area.sql"; target=blissey
  else
    file="$SQL_DIR/procedures/quest_area_external.sql"; target=scanner
  fi
  echo "Creating procedure rpl5questarea ($target)"
  if [[ "${BLISSEY_DRY_RUN:-0}" == 1 ]]; then
    echo "DRY-RUN: $file -> $target"
    return 0
  fi
  render_procedure "$file" | "mysql_$target"
}

# render_procedure <file> — substitute database names and enable the Koji or non-Koji
# variant of the fence lookup (lines prefixed with "-- useKoji " / "-- nonKoji ").
render_procedure() {
  local file=$1 sed_args=()
  if is_true "$geofences_use_koji"; then
    sed_args+=(-e "s/project_controller/${geofences_koji_project}/g" -e "s/^-- useKoji //")
    if has_fort_areas; then
      sed_args+=(-e "s/fortarray/$(fort_areas_sql)/g")
    else
      sed_args+=(-e "s/ and a.name not in (fortarray)//")
    fi
  else
    sed_args+=(-e "s/^-- nonKoji //")
  fi
  sql_substitute "$file" | sed "${sed_args[@]}"
}
