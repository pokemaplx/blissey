#!/usr/bin/env bash
# Interactive helper: run a Rotom job (as defined in Rotom's jobs.json) on one device or on
# every device. Uses [rotom] api_host / api_port from config.toml.

BLISSEY_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
export BLISSEY_ROOT
# shellcheck source=../../lib/common.sh
source "$BLISSEY_ROOT/lib/common.sh"
# shellcheck source=../../lib/config.sh
source "$BLISSEY_ROOT/lib/config.sh"
load_config

api="http://$rotom_api_host:$rotom_api_port"
command -v jq > /dev/null 2>&1 || die "jq is required"

# pick <prompt> <options...> — print the chosen option
pick() {
  local prompt=$1 n=0 option choice; shift
  echo "" >&2
  echo "$prompt" >&2
  for option in "$@"; do
    n=$((n + 1))
    printf '[%s] %s\n' "$n" "$option" >&2
  done
  printf 'Enter number (1 to %s): ' "$n" >&2
  read -r choice
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > n )); then
    die "wrong selection"
  fi
  echo "${@:$choice:1}"
}

mapfile -t jobs < <(curl -s "$api/api/job/list" | jq -r '.[].id')
(( ${#jobs[@]} > 0 )) || die "no jobs found at $api/api/job/list"
job=$(pick "Select a job" "${jobs[@]}")

mapfile -t devices < <(curl -s "$api/api/status" | jq -r '.devices[].deviceId' | sort -u)
(( ${#devices[@]} > 0 )) || die "no devices found at $api/api/status"
device=$(pick "Select a device" "${devices[@]}" "All")

if [[ "$device" == "All" ]]; then
  printf '\nSeconds to wait between devices: '
  read -r wait
  [[ "$wait" =~ ^[0-9]+$ ]] || die "not a number: $wait"
  for device in "${devices[@]}"; do
    echo "executing $job on $device"
    curl -s -X POST "$api/api/job/execute/$job/$device"
    echo ""
    sleep "$wait"
  done
else
  echo ""
  echo "executing $job on $device"
  curl -s -X POST "$api/api/job/execute/$job/$device"
  echo ""
fi
echo "All done."
