#!/bin/sh
# Reports what looks wrong with a gdk-oc instance; prints OK and exits 0 when
# it finds nothing, exits 1 otherwise, so cron or launchd can act on it.
#
#   sh oc/scripts/gdk-healthcheck.sh
#
# Every check here is something that actually went wrong and took a while to
# recognise, which is the bar for adding another: each one names the symptom it
# would have short-circuited.
GDK=${GDK_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
problems=0
say() { echo "$@"; problems=$((problems + 1)); }

# 1. Services. runsv reports "run" for up, "down" otherwise.
for svc in rails-web rspack rails-background-jobs postgresql redis; do
  pid=$(cat "$GDK/services/$svc/supervise/pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || say "DOWN: $svc"
done

# 2. Sidekiq footprint. It reached 9.9 GB over ~2.5 days once; ps RSS
#    undercounts badly on macOS, so read top's physical footprint.
sk=$(pgrep -f "sidekiq 7" | head -1)
if [ -n "$sk" ]; then
  mem=$(top -l 1 -pid "$sk" -stats mem 2>/dev/null | tail -1 | tr -d ' ')

  # Growth curve, recorded every run whether or not anything is wrong: launchd
  # only keeps output on failure, so without this there is no history to
  # correlate against job activity. heap_live_slots is the figure that
  # distinguishes a retention leak from fragmentation -- 58.5M live objects
  # surviving 247 major GCs is what the 10 GB occurrence looked like, against
  # 3.4M for a freshly started process.
  # Restart threshold, and the floor on how often a restart may happen.
  RESTART_GB=${SIDEKIQ_RESTART_GB:-4}
  RESTART_MIN_HOURS=${SIDEKIQ_RESTART_MIN_HOURS:-20}
  rstamp=$HOME/Library/Logs/.gdk-oc-sidekiq-restarted
  RCLI=/opt/homebrew/bin/redis-cli
  SV=/opt/homebrew/bin/sv

  csv=$HOME/Library/Logs/gdk-oc-sidekiq-memory.csv
  [ -f "$csv" ] || echo "timestamp,pid,uptime,mem,heap_live_slots,heap_free_slots,major_gc" > "$csv"
  live=; free=; major=
  # GC.stat is O(1); never call count_objects_size here, which walks the whole
  # heap and takes minutes once it is large.
  rb=$HOME/.local/share/mise/installs/ruby/3.3.11/bin
  if [ -x "$rb/bundle" ] && [ -x /opt/homebrew/bin/timeout ]; then
    stat=$(cd "$REPO" && PATH="$rb:$PATH" /opt/homebrew/bin/timeout 30 bundle exec rbtrace -p "$sk" \
      -e 'g=GC.stat; "%d,%d,%d" % [g[:heap_live_slots], g[:heap_free_slots], g[:major_gc_count]]' 2>/dev/null \
      | grep -oE '[0-9]+,[0-9]+,[0-9]+' | head -1)
    if [ -n "$stat" ]; then
      live=${stat%%,*}; rest=${stat#*,}; free=${rest%%,*}; major=${rest#*,}
    fi
  fi
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date '+%Y-%m-%d %H:%M')" "$sk" \
    "$(ps -o etime= -p "$sk" | tr -d ' ')" "$mem" "$live" "$free" "$major" >> "$csv"

  # Restart once it is large. The cause is known and is not a job: development
  # code reloading retains a whole Grape API generation per reload (103 of them
  # reached 10 GB on 2026-09-14), and only a restart reclaims it.
  # CACHE_CLASSES=true would prevent it, at the cost of a restart after every
  # worker edit. Diagnosis recipe, if it ever looks different from that:
  # ENABLE_RBTRACE=1 is already in env.runit, so `bundle exec rbtrace -p <pid>`
  # attaches; GC.stat is O(1) and safe, count_objects_size and dump_all walk the
  # whole heap and must be backgrounded in a Thread rather than joined.
  case "$mem" in
    *G) n=${mem%G}
        if [ "${n%%.*}" -ge "$RESTART_GB" ] 2>/dev/null; then
          # A restart is only safe when nothing is in flight: runit sends TERM
          # and sidekiq gives running jobs 25s before it is killed.
          busy=0
          if [ -x "$RCLI" ]; then
            for proc in $("$RCLI" -s "$GDK/redis/redis.socket" -n 1 smembers processes 2>/dev/null); do
              b=$("$RCLI" -s "$GDK/redis/redis.socket" -n 1 hget "$proc" busy 2>/dev/null)
              busy=$((busy + ${b:-0}))
            done
          fi

          if [ "$busy" -gt 0 ]; then
            say "SIDEKIQ MEMORY: $mem in pid $sk -- not restarting, $busy job(s) in flight"
          elif [ -f "$rstamp" ] && [ -z "$(find "$rstamp" -mmin +$((60 * RESTART_MIN_HOURS)) 2>/dev/null)" ]; then
            say "SIDEKIQ MEMORY: $mem in pid $sk -- already restarted within ${RESTART_MIN_HOURS}h"
          elif [ -x "$SV" ]; then
            if "$SV" restart "$GDK/services/rails-background-jobs" >/dev/null 2>&1; then
              touch "$rstamp"
              say "SIDEKIQ RESTARTED: was $mem in pid $sk"
            else
              say "SIDEKIQ RESTART FAILED: $mem in pid $sk"
            fi
          else
            say "SIDEKIQ MEMORY: $mem in pid $sk -- cannot restart, $SV not found"
          fi
        fi ;;
  esac
fi

# 3. rspack compile errors since the last check.
log=$GDK/log/rspack/current
if [ -f "$log" ]; then
  errs=$(tail -300 "$log" | grep -cE "ESModulesLinkingError|Module not found|ERROR in")
  [ "$errs" -gt 0 ] && say "RSPACK: $errs compile errors in the last 300 log lines (a stale tmp/infection_scanner.json looks like this)"
fi

# 4. GraphQL answering at all. The 'Can't reinstall subscriptions' reload fault
#    500s every query until Rails restarts, and nothing else shows it.
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://gdk.test:3000/api/graphql \
  -H 'Content-Type: application/json' -d '{"query":"{ __typename }"}' 2>/dev/null)
[ "$code" = "200" ] || say "GRAPHQL: POST /api/graphql returned $code (restart rails-web if 500)"

# 5. Things that must never be committed.
cd "$REPO" 2>/dev/null || exit 0
git diff --quiet -- package.json yarn.lock 2>/dev/null || \
  say "WORKTREE: package.json/yarn.lock modified -- a link: resolution must not be committed"
if git status --porcelain oc/app/assets/javascripts/dashboard 2>/dev/null | grep -q .; then
  echo "note: oc-pages symlinks point at a local checkout (expected while linking; git restore to undo)"
fi

# 6. Worker failures. GitLab's Sidekiq keeps its dead set in its own Redis db,
#    so a plain `zcard dead` reads empty -- use its log instead. Four EE-only
#    cron jobs are registered in this edition and cannot resolve their classes,
#    so `uninitialized constant` here is expected background noise until those
#    are removed from the schedule.
jlog=$GDK/log/rails-background-jobs/current
if [ -f "$jlog" ]; then
  fails=$(tail -800 "$jlog" | grep -ciE '"severity":"(ERROR|FATAL)"|uninitialized constant')
  [ "$fails" -gt 0 ] && say "SIDEKIQ: $fails error/fatal lines in the last 800 log lines"
fi

[ "$problems" -eq 0 ] || exit 1
echo "OK"
