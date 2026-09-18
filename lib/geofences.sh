#!/usr/bin/env bash
# Enrich table `geofences` after fences were inserted or changed (manual fence mode only,
# with use_koji=true the fences come straight from the Koji database):
#   st / st_lonlat  polygon geometry in "lat lon" and "lon lat" order
#   km2             fence area (needs Planimeter from geographiclib-tools)
#   utcoffset       timezone offset + country code via api.wheretheiss.at

TZ_API_CALLS=0

geofences_update() {
  if is_true "$geofences_use_koji"; then
    echo "use_koji=true: fences are read from Koji, nothing to update."
    return 0
  fi
  log "[$(now)] geofences update executed"
  geofences_geometry
  geofences_km2
  geofences_timezone || die "timezone lookup failed, rerun 'blissey geofences' to continue"
  echo "Geofences updated."
}

geofences_rows() {
  mysql_blissey -NB -e "select area, fence, type, coords from geofences;"
}

geofences_geometry() {
  echo "Updating polygon geometry (st, st_lonlat)"
  local area fence type coords reverse
  while IFS=$'\t' read -r area fence type coords; do
    reverse=$(echo "$coords" | tr ',' '\n' | awk '{ print $2, $1 }' | paste -sd, -)
    mysql_blissey -e "update geofences set st = st_geomfromtext('POLYGON(($coords))'), st_lonlat = st_geomfromtext('POLYGON(($reverse))') where area = '$area' and fence = '$fence' and type = '$type';"
  done < <(geofences_rows)
}

geofences_km2() {
  if ! command -v Planimeter > /dev/null 2>&1; then
    warn "Planimeter not installed (apt install geographiclib-tools), skipping km2"
    return 0
  fi
  echo "Updating km2"
  local area fence type coords km2
  while IFS=$'\t' read -r area fence type coords; do
    km2=$(echo "$coords" | sed 's/, */,/g' | tr ',' '\n' | Planimeter | awk '{ v = $3 / 1000000; if (v < 0) v = -v; print v }')
    mysql_blissey -e "update geofences set km2 = '$km2' where area = '$area' and fence = '$fence' and type = '$type';"
  done < <(geofences_rows)
}

geofences_timezone() {
  echo "Updating utcoffset and country (api.wheretheiss.at)"
  local area fence type coord

  # Quest fences first: one lookup per area prefix (text before the first "_") covers all
  # fences of that area, which keeps the number of API calls low.
  while IFS=$'\t' read -r area fence type coord; do
    tz_update "$coord" "area like concat('${area%%_*}', '%')" || return 1
  done < <(geofences_centroids "type = 'quest'")

  # Whatever is still missing (mon-only areas, fences without a quest counterpart).
  while IFS=$'\t' read -r area fence type coord; do
    tz_update "$coord" "area = '$area' and fence = '$fence' and type = '$type'" || return 1
  done < <(geofences_centroids "utcoffset is null")
}

# geofences_centroids <where> — "area fence type lat lon" for fences with geometry
geofences_centroids() {
  mysql_blissey -NB -e "select area, fence, type, replace(replace(st_astext(st_centroid(st)), 'POINT(', ''), ')', '') from geofences where st is not null and $1;"
}

# tz_update <"lat lon"> <where clause> — look the centroid up and store offset + country
tz_update() {
  local coord=${1/ /,} where=$2 result offset country
  if (( TZ_API_CALLS >= 300 )); then
    echo "300 API calls done, sleeping 60s to respect the rate limit"
    sleep 60
    TZ_API_CALLS=0
  fi
  result=$(curl -s -k -L --fail --show-error "https://api.wheretheiss.at/v1/coordinates/$coord")
  TZ_API_CALLS=$((TZ_API_CALLS + 1))
  [[ -n "$result" ]] || { echo "timezone API returned nothing for $coord" >&2; return 1; }
  offset=$(echo "$result" | jq -r '.offset // empty')
  country=$(echo "$result" | jq -r '.country_code // empty')
  [[ -n "$offset" ]] || { echo "timezone API returned no offset for $coord: $result" >&2; return 1; }
  mysql_blissey -e "update geofences set utcoffset = $offset, country = '$country' where $where;"
}
