#!/usr/bin/env bash
# green-stats: incremental Claude Code usage collection + energy estimate.
#
# Portable by design: bash 3.2+, POSIX awk (mawk/BSD awk/gawk), GNU or BSD
# userland, BusyBox sh inside containers. No jq, no python.
#
#   green-stats.sh check                       environment report
#   green-stats.sh collect                     ingest new transcript data
#   green-stats.sh report [--days N] [--by model|day|source] [--no-collect]
#   green-stats.sh reset                       drop cached state and usage
#
# Data lives in $GREEN_STATS_HOME (default ~/.local/share/green-stats):
#   config.json              settings, one key per line
#   state/<source>.jsonl     per-file read offsets
#   state/containers.jsonl   per-container scan markers
#   usage/YYYY-MM.jsonl      one record per assistant message

set -u
export LC_ALL=C

PLUGIN_ROOT=$(cd "$(dirname "$0")/.." && pwd)
GS_HOME=${GREEN_STATS_HOME:-$HOME/.local/share/green-stats}
CONFIG=$GS_HOME/config.json
STATE=$GS_HOME/state
USAGE=$GS_HOME/usage
TAB=$(printf '\t')

N_READ=0 N_SKIP=0 N_BYTES=0 C_SCAN=0 C_SKIP=0

die() { echo "green-stats: $*" >&2; exit 1; }

# cfg KEY DEFAULT: read a scalar from the flat config.json
cfg() {
  local re v
  re=$(printf '%s' "$1" | sed 's/[.]/\\./g')
  v=$(sed -n 's/^[[:space:]]*"'"$re"'"[[:space:]]*:[[:space:]]*//p' "$CONFIG" 2>/dev/null |
    head -n 1 | sed 's/[[:space:]]*,*[[:space:]]*$//; s/^"//; s/"$//')
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf '%s\n' "$2"; fi
}

jesc() { local s=${1//\\/\\\\}; printf '%s' "${s//\"/\\\"}"; }

now_secs() {
  if [ -n "${EPOCHREALTIME:-}" ]; then printf '%s\n' "$EPOCHREALTIME"; else date +%s; fi
}

if stat -c %s / >/dev/null 2>&1; then STAT_OPT=-c STAT_FMT='%s %Y %n'; else STAT_OPT=-f STAT_FMT='%z %m %N'; fi

# ---------------------------------------------------------------- awk code

# Minimal JSON accessors shared by every awk program.
JLIB='
function jstr(s, k,   p, i, n, c, out) {
  p = index(s, "\"" k "\":\""); if (!p) return ""
  n = length(s); out = ""
  for (i = p + length(k) + 4; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; out = out substr(s, i, 1); continue }
    if (c == "\"") break
    out = out c
  }
  return out
}
function lastjstr(s, k,   pat, p, off) {
  pat = "\"" k "\":\""; off = 0
  while ((p = index(substr(s, off + 1), pat)) > 0) off += p
  return off ? jstr(substr(s, off), k) : ""
}
function jnum(s, k,   p, t) {
  p = index(s, "\"" k "\":"); if (!p) return 0
  t = substr(s, p + length(k) + 3, 32)
  if (match(t, /^-?[0-9.]+/)) return substr(t, 1, RLENGTH) + 0
  return 0
}
function jesc(s,   i, c, o) {
  if (!index(s, "\\") && !index(s, "\"")) return s
  o = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\" || c == "\"") o = o "\\"; o = o c }
  return o
}
'

# Transcript segment -> usage records appended to udir/YYYY-MM.jsonl.
# Prints the number of bytes consumed (complete lines only).
PARSE='
function emit(line,   m, u, rest, model, id, req, ts, key) {
  m = index(line, "\"message\":{"); if (!m) return
  if (!index(substr(line, m, 400), "\"role\":\"assistant\"")) return
  # the real usage object starts with input_tokens; nested "iterations" repeat
  # the counters later, and unescaped tool inputs can contain anything
  u = index(line, "\"usage\":{\"input_tokens\":"); if (!u) return
  rest = substr(line, m)
  model = jstr(rest, "model"); if (model == "" || model == "<synthetic>") return
  id = jstr(rest, "id")
  req = lastjstr(line, "requestId")
  ts = lastjstr(line, "timestamp"); if (ts == "") return
  key = (id != "") ? id "|" req : lastjstr(line, "uuid")
  rest = substr(line, u + 9)
  printf "{\"key\":\"%s\",\"ts\":\"%s\",\"model\":\"%s\",\"source\":\"%s\",\"in\":%d,\"out\":%d,\"cw\":%d,\"cr\":%d}\n", \
    jesc(key), jesc(ts), jesc(model), jesc(src), \
    jnum(rest, "input_tokens"), jnum(rest, "output_tokens"), \
    jnum(rest, "cache_creation_input_tokens"), jnum(rest, "cache_read_input_tokens") \
    >> (udir "/" substr(ts, 1, 7) ".jsonl")
}
{
  n = length($0) + 1; bytes += n
  if (have) emit(pend)
  pend = $0; have = 1; lastn = n
}
END {
  # a final line without its newline is still being written: leave it
  if (have) { if (bytes > seglen) bytes -= lastn; else emit(pend) }
  print bytes + 0
}
'

# Previous state + current listing -> K(eep)/C(hanged) lines with offsets.
DIFF='
FILENAME == sf { p = jstr($0, "path"); osz[p] = jnum($0, "size"); omt[p] = jnum($0, "mtime"); ooff[p] = jnum($0, "offset"); next }
{
  sz = $1; mt = sizeonly ? 0 : $2
  p = $0; sub(/^[^ ]+ [^ ]+ /, "", p); sub(/^\.\//, "", p)
  if ((p in osz) && osz[p] == sz && omt[p] == mt) { print "K\t" ooff[p] "\t" sz "\t" mt "\t" p; next }
  off = ((p in ooff) && ooff[p] <= sz) ? ooff[p] : 0
  print "C\t" off "\t" sz "\t" mt "\t" p
}
'

# ---------------------------------------------------------------- collect

# collect_tree SOURCE STATEFILE MODE ROOT [CONTAINER]
#   MODE local: ROOT is a local directory
#   MODE exec:  ROOT is a directory inside a running CONTAINER
collect_tree() {
  local src=$1 sf=$2 mode=$3 root=$4 cid=${5:-} sizeonly=0
  local listing=$TMPD/listing plan=$TMPD/plan new=$TMPD/state.new
  local st off sz mt rel len used
  case $mode in
    local)
      case $src in docker:*) sizeonly=1 ;; esac
      (cd "$root" 2>/dev/null && find . -type f -name '*.jsonl' -exec stat "$STAT_OPT" "$STAT_FMT" {} +) >"$listing" 2>/dev/null ;;
    exec)
      sizeonly=1
      "$RT" exec "$cid" sh -c 'cd "$1" && find . -type f -name "*.jsonl" -exec wc -c {} +' sh "$root" 2>/dev/null |
        awk '{ sub(/^ +/, ""); n = index($0, " "); p = substr($0, n + 1); if (substr(p, 1, 2) == "./") print substr($0, 1, n - 1) " 0 " p }' >"$listing" ;;
  esac
  [ -f "$sf" ] || : >"$sf"
  awk -v sf="$sf" -v sizeonly=$sizeonly "$JLIB$DIFF" "$sf" - <"$listing" >"$plan"
  : >"$new"
  while IFS=$TAB read -r st off sz mt rel <&3; do
    if [ "$st" = C ] && [ "$sz" -gt "$off" ]; then
      len=$((sz - off))
      case $mode in
        local) tail -c "+$((off + 1))" "$root/$rel" ;;
        exec) "$RT" exec "$cid" tail -c "+$((off + 1))" "$root/$rel" 2>/dev/null ;;
      esac | head -c "$len" | awk -v src="$src" -v seglen="$len" -v udir="$USAGE" "$JLIB$PARSE" >"$TMPD/used"
      read -r used <"$TMPD/used"
      off=$((off + ${used:-0})); N_READ=$((N_READ + 1)); N_BYTES=$((N_BYTES + ${used:-0}))
    else
      N_SKIP=$((N_SKIP + 1))
    fi
    printf '{"source":"%s","path":"%s","size":%s,"mtime":%s,"offset":%s}\n' \
      "$(jesc "$src")" "$(jesc "$rel")" "$sz" "$mt" "$off" >>"$new"
  done 3<"$plan"
  mv "$new" "$sf"
}

collect_host() {
  [ "$(cfg host true)" = true ] || return 0
  local roots root id IFS_SAVE=$IFS
  roots="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects:$(cfg extra_paths '')"
  IFS=:
  for root in $roots; do
    IFS=$IFS_SAVE
    [ -n "$root" ] && [ -d "$root" ] || continue
    id=$(printf '%s' "$root" | cksum | cut -d' ' -f1)
    collect_tree host "$STATE/host-$id.jsonl" local "$root"
  done
  IFS=$IFS_SAVE
}

# copy a stopped (or exec-less) container's transcripts out and ingest them
collect_container_cp() {
  local id=$1 name=$2 short=$3 cands=$4 d out=$TMPD/cp
  rm -rf "$out"; mkdir -p "$out"
  for d in $cands; do
    if "$RT" cp "$id:$d" - 2>/dev/null | tar -xf - -C "$out" 2>/dev/null && [ -d "$out/projects" ]; then
      collect_tree "docker:$name" "$STATE/docker-$short.jsonl" local "$out/projects"
      rm -rf "$out"; FOUND=$d; return 0
    fi
  done
  rm -rf "$out"; FOUND=
}

collect_containers() {
  [ "$(cfg devcontainers false)" = true ] || return 0
  RT=$(cfg container_runtime docker)
  command -v "$RT" >/dev/null 2>&1 || return 0
  local ids cstate=$STATE/containers.jsonl new=$TMPD/containers.new
  local id running fin name user short ppath cands h path rc
  ids=$("$RT" ps -aq --no-trunc 2>/dev/null) || return 0
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  "$RT" inspect -f '{{.Id}} {{.State.Running}} {{.State.FinishedAt}} {{.Name}} {{.Config.User}}' $ids >"$TMPD/inspect" 2>/dev/null
  [ -f "$cstate" ] || : >"$cstate"
  # one pass decides which containers changed; unchanged ones keep their line
  awk -v sf="$cstate" -v new="$new" -v todo="$TMPD/todo" "$JLIB"'
    FILENAME == sf { line[jstr($0, "id")] = $0; fin[jstr($0, "id")] = jstr($0, "finished_at"); path[jstr($0, "id")] = jstr($0, "claude_path"); next }
    ($1 in line) && $2 != "true" && fin[$1] == $3 { print line[$1] > new; skipped++; next }
    { print $0 "\t" path[$1] > todo }
    END { print skipped + 0 }' "$cstate" "$TMPD/inspect" >"$TMPD/skipped"
  read -r C_SKIP <"$TMPD/skipped"
  [ -f "$new" ] || : >"$new"
  [ -f "$TMPD/todo" ] || : >"$TMPD/todo"
  while IFS=$TAB read -r id ppath <&3; do
    set -- $id; id=$1 running=$2 fin=$3 name=${4#/} user=${5:-}
    short=$(printf '%.12s' "$id")
    C_SCAN=$((C_SCAN + 1))
    cands=$ppath
    for h in $(cfg container_homes '/root /home/node /home/vscode'); do cands="$cands $h/.claude/projects"; done
    case $user in '' | [0-9]* | root) ;; *) cands="$cands /home/${user%%:*}/.claude/projects" ;; esac
    path=; rc=1
    if [ "$running" = true ]; then
      path=$("$RT" exec "$id" sh -c 'for d in "$HOME/.claude/projects" $1; do [ -d "$d" ] && { echo "$d"; exit 0; }; done; exit 3' sh "$cands" 2>/dev/null)
      rc=$?
      [ $rc -eq 0 ] && collect_tree "docker:$name" "$STATE/docker-$short.jsonl" exec "$path" "$id"
    fi
    if [ $rc -ne 0 ] && [ $rc -ne 3 ]; then
      collect_container_cp "$id" "$name" "$short" "$cands"; path=$FOUND
    fi
    printf '{"id":"%s","name":"%s","finished_at":"%s","claude_path":"%s"}\n' \
      "$id" "$(jesc "$name")" "$fin" "$(jesc "$path")" >>"$new"
  done 3<"$TMPD/todo"
  mv "$new" "$cstate"
}

collect() {
  local t0 t1
  t0=$(now_secs)
  mkdir -p "$STATE" "$USAGE"
  collect_host
  collect_containers
  t1=$(now_secs)
  awk -v a="$t0" -v b="$t1" -v r=$N_READ -v s=$N_SKIP -v by=$N_BYTES -v cs=$C_SCAN -v ck=$C_SKIP -v dc="$(cfg devcontainers false)" 'BEGIN {
    line = sprintf("collect: files %d read / %d unchanged (%.1f MB new)", r, s, by / 1048576)
    if (dc == "true") line = line sprintf(" · containers %d scanned / %d unchanged", cs, ck)
    printf "%s · %.1fs\n", line, b - a
  }'
}

# ---------------------------------------------------------------- report

REPORT='
function hum(n) {
  if (n >= 1e9) return sprintf("%.2fB", n / 1e9)
  if (n >= 1e6) return sprintf("%.2fM", n / 1e6)
  if (n >= 1e3) return sprintf("%.1fk", n / 1e3)
  return sprintf("%d", n)
}
function energy(wh) {
  if (wh >= 1e6) return sprintf("%.2f MWh", wh / 1e6)
  if (wh >= 1e3) return sprintf("%.2f kWh", wh / 1e3)
  return sprintf("%.1f Wh", wh)
}
function tier(m,   k) {
  if (m in tiercache) return tiercache[m]
  for (k in cfg) if (substr(k, 1, 9) == "tier_map." && index(m, substr(k, 10))) return tiercache[m] = cfg[k]
  if (index(m, "opus")) return tiercache[m] = "opus"
  if (index(m, "sonnet")) return tiercache[m] = "sonnet"
  if (index(m, "haiku")) return tiercache[m] = "haiku"
  unmapped[m] = 1
  return tiercache[m] = "default"
}
function coef(t, kind,   k) {
  k = "wh_per_mtok." t "." kind
  if (k in cfg) return cfg[k]
  return cfg["wh_per_mtok.default." kind] + 0
}
FILENAME == cf {
  if (match($0, /^[ \t]*"[^"]+"[ \t]*:/)) {
    k = substr($0, RSTART, RLENGTH); sub(/^[ \t]*"/, "", k); sub(/"[ \t]*:$/, "", k)
    v = substr($0, RSTART + RLENGTH); sub(/^[ \t]*/, "", v); sub(/[ \t]*,?[ \t]*$/, "", v); gsub(/"/, "", v)
    cfg[k] = v
  }
  next
}
{
  k = jstr($0, "key")
  i = jnum($0, "in"); o = jnum($0, "out"); w = jnum($0, "cw"); r = jnum($0, "cr")
  if (k in rf) {
    dup[FILENAME]++
    if (i > IN[k]) IN[k] = i; if (o > OUT[k]) OUT[k] = o
    if (w > CW[k]) CW[k] = w; if (r > CR[k]) CR[k] = r
    next
  }
  rf[k] = FILENAME; TS[k] = jstr($0, "ts"); MD[k] = jstr($0, "model"); SRC[k] = jstr($0, "source")
  IN[k] = i; OUT[k] = o; CW[k] = w; CR[k] = r
}
END {
  pue = cfg["pue"] + 0; if (pue <= 0) pue = 1
  for (k in rf) {
    if (dup[rf[k]])
      printf "{\"key\":\"%s\",\"ts\":\"%s\",\"model\":\"%s\",\"source\":\"%s\",\"in\":%d,\"out\":%d,\"cw\":%d,\"cr\":%d}\n", \
        jesc(k), jesc(TS[k]), jesc(MD[k]), jesc(SRC[k]), IN[k], OUT[k], CW[k], CR[k] >> (rf[k] ".tmp")
    if (TS[k] < start) continue
    g = (by == "day") ? substr(TS[k], 1, 10) : (by == "source") ? SRC[k] : MD[k]
    t = tier(MD[k])
    wh = (IN[k] * coef(t, "input") + OUT[k] * coef(t, "output") + CW[k] * coef(t, "cache_write") + CR[k] * coef(t, "cache_read")) / 1e6 * pue
    gn[g]++; gi[g] += IN[k]; go[g] += OUT[k]; gw[g] += CW[k]; gr[g] += CR[k]; gwh[g] += wh
    tn++; ti += IN[k]; to += OUT[k]; tw += CW[k]; tr += CR[k]; twh += wh
  }
  fmt = "%-28s %7s %9s %9s %12s %12s %10s %11s\n"
  printf fmt, "", "msgs", "input", "output", "cache write", "cache read", "total", "energy" > head
  printf fmt, "total", tn + 0, hum(ti), hum(to), hum(tw), hum(tr), hum(ti + to + tw + tr), energy(twh) > head
  printf "\n" fmt, "by " by, "", "", "", "", "", "", "" > head
  for (g in gn) {
    sk = (by == "day") ? g : sprintf("%020d", gi[g] + go[g] + gw[g] + gr[g])
    printf "%s\t" fmt, sk, substr(g, 1, 28), gn[g], hum(gi[g]), hum(go[g]), hum(gw[g]), hum(gr[g]), hum(gi[g] + go[g] + gw[g] + gr[g]), energy(gwh[g]) > rows
  }
  lo = cfg["estimate_low_factor"] + 0; hi = cfg["estimate_high_factor"] + 0
  printf "\nenergy (estimate, model %s): %s (range %s – %s), %.1f kg CO2e at %s gCO2/kWh, PUE %s\n", \
    cfg["energy_model_version"], energy(twh), energy(twh * lo), energy(twh * hi), \
    twh / 1000 * cfg["grid_gco2_per_kwh"] / 1000, cfg["grid_gco2_per_kwh"], pue > foot
  nu = 0; for (m in unmapped) { ul = ul (nu++ ? ", " : "") m }
  if (nu) printf "unmapped models (counted as default tier): %s\n", ul > foot
}
'

report() {
  local days by="model" do_collect=1 start_epoch start smonth f m files=
  days=$(cfg default_days 30)
  while [ $# -gt 0 ]; do
    case $1 in
      --days) days=$2; shift 2 ;;
      --by) by=$2; shift 2 ;;
      --no-collect) do_collect=0; shift ;;
      *) die "unknown report option: $1" ;;
    esac
  done
  case $by in model | day | source) ;; *) die "--by must be model, day or source" ;; esac
  [ $do_collect -eq 1 ] && collect
  start_epoch=$(($(date -u +%s) - days * 86400))
  start=$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r "$start_epoch" +%Y-%m-%dT%H:%M:%S)
  smonth=$(printf '%.7s' "$start")
  for f in "$USAGE"/*.jsonl; do
    [ -f "$f" ] || continue
    m=$(basename "$f" .jsonl)
    [ "$m" \< "$smonth" ] || files="$files $f"
  done
  [ -n "$files" ] || { echo "no usage recorded since $start"; return 0; }
  rm -f "$USAGE"/*.jsonl.tmp
  echo
  echo "green-stats: last $days days (since $(printf '%.16s' "$start" | tr T ' ') UTC)"
  echo
  # shellcheck disable=SC2086
  awk -v cf="$CONFIG" -v start="$start" -v by="$by" \
    -v head="$TMPD/head" -v rows="$TMPD/rows" -v foot="$TMPD/foot" \
    "$JLIB$REPORT" "$CONFIG" $files
  cat "$TMPD/head"
  if [ "$by" = day ]; then sort "$TMPD/rows"; else sort -r "$TMPD/rows"; fi | cut -f2-
  cat "$TMPD/foot"
  # compaction: files that contained duplicate records were rewritten deduplicated
  for f in "$USAGE"/*.jsonl.tmp; do [ -f "$f" ] && mv "$f" "${f%.tmp}"; done
  return 0
}

# ---------------------------------------------------------------- misc

check() {
  local rt
  echo "bash:        $BASH_VERSION"
  echo "awk:         $(command -v awk || echo MISSING)"
  echo "stat style:  $(case $STAT_OPT in -c) echo GNU/BusyBox ;; *) echo BSD ;; esac)"
  for t in find tail head cksum sort tar; do command -v $t >/dev/null 2>&1 || echo "missing:     $t"; done
  for rt in docker podman; do
    if command -v $rt >/dev/null 2>&1; then echo "runtime:     $rt ($($rt ps -aq 2>/dev/null | wc -l | tr -d ' ') containers)"; fi
  done
  echo "transcripts: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  echo "data dir:    $GS_HOME"
  echo "config:      $( [ -f "$CONFIG" ] && echo "$CONFIG" || echo "none (run setup)")"
}

main() {
  local cmd=${1:-report}; [ $# -gt 0 ] && shift
  case $cmd in
    check) check; return ;;
    reset) rm -rf "$STATE" "$USAGE"; echo "cache cleared: $GS_HOME"; return ;;
    collect | report) ;;
    *) die "usage: green-stats.sh check|collect|report|reset" ;;
  esac
  [ -f "$CONFIG" ] || { mkdir -p "$GS_HOME"; cp "$PLUGIN_ROOT/config/default-config.json" "$CONFIG"; }
  mkdir "$GS_HOME/.lock" 2>/dev/null || die "another run is in progress (remove $GS_HOME/.lock if stale)"
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/green-stats.XXXXXX")
  trap 'rm -rf "$TMPD"; rmdir "$GS_HOME/.lock" 2>/dev/null' EXIT INT TERM
  "$cmd" "$@"
}

main "$@"
