# Convert Go time.Duration strings (as printed in dragonite.log) to a number.
#
#   echo "1m2.5s"  | awk -f duration.awk            -> 62500     (milliseconds, default)
#   echo "456ms"   | awk -f duration.awk            -> 456
#   echo "12µs"    | awk -f duration.awk            -> 0.012
#   echo "1h2m30s" | awk -v unit=min -f duration.awk -> 62       (whole minutes)
#
# One duration per input line (only the first field is read); blank lines are skipped.
# Unparseable input yields 0 rather than breaking the caller's aggregation.

BEGIN { OFMT = "%.3f"; CONVFMT = "%.3f" }

function to_ms(s,    ms, token, num, u) {
  ms = 0
  while (match(s, /^[0-9]+(\.[0-9]+)?(ns|µs|μs|us|ms|s|m|h)/)) {
    token = substr(s, RSTART, RLENGTH)
    s = substr(s, RSTART + RLENGTH)
    u = token; sub(/^[0-9.]+/, "", u)
    num = token + 0
    if (u == "h")       ms += num * 3600000
    else if (u == "m")  ms += num * 60000
    else if (u == "s")  ms += num * 1000
    else if (u == "ms") ms += num
    else if (u == "ns") ms += num / 1000000
    else                ms += num / 1000          # µs / μs / us
  }
  return ms
}

NF {
  ms = to_ms($1)
  if (unit == "min") print int(ms / 60000)
  else if (ms == int(ms)) printf "%d\n", ms
  else print ms
}
