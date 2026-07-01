#!/usr/bin/env bash
# Claude Code status line (Git Bash version).
#   >> <folder> [<branch> posh-git status]  |  ctx  |  usg <quota>  |  model effort
#
# Why bash, not PowerShell: on Chinese Windows the console code page is 936; a PowerShell
# statusline mis-decodes the UTF-8 session JSON coming in on stdin and ConvertFrom-Json fails,
# so the bar collapses to "[no git]". Git Bash reads stdin as raw UTF-8 bytes -- no code-page
# problem. This also sidesteps the v2.1.x PowerShell-statusline regression (issue #30725).
#
# coreutils (grep/sed/date) live in /usr/bin and git in /mingw64/bin; when Claude Code invokes
# `bash` from outside, that PATH isn't set up, so we add it explicitly.
#
# Perf note: on Git Bash every `$(...)` forks a subshell (~65ms via cygwin fork emulation),
# so the old "$(c ...)"/"$(field ...)" style cost seconds per render. This version builds
# colored strings by inlining the ANSI codes, parses the JSON with bash's own `=~` (no grep),
# and uses `printf -v` instead of "$(round ...)" -- leaving only git as an external command.
export PATH="/usr/bin:/mingw64/bin:$PATH"

IFS= read -r -d '' raw || true        # slurp stdin JSON without forking `cat`

E=$'\033'                              # ESC; colored text = ${E}[<code>m<text>${E}[0m
HOT='38;2;255;92;87'      # bright red
WARN='38;2;255;138;60'    # amber
ACCENT='38;2;160;160;160' # muted gray for labels / separators
# tier color into global PC: >=90 red, >=70 amber, else caller's default (ctx=cyan 36, usg=green 32)
pctcol() { local def="${2:-32}"; if [ "$1" -ge 90 ]; then PC="$HOT"; elif [ "$1" -ge 70 ]; then PC="$WARN"; else PC="$def"; fi; }

# field PATTERN: match $raw with a bash ERE (one capture group) into global F. No subprocess.
field() { if [[ "$raw" =~ $1 ]]; then F="${BASH_REMATCH[1]}"; else F=""; fi; }

# visible width, pure bash (no subprocess, no locale): walk the string, skip ANSI
# escape sequences (ESC..m), count the rest by bytes. CJK counts as 3 bytes (>2 real
# cols) -> a slight over-estimate, so the bar wraps a touch early. Safe and fast.
vwidth() {                   # result into global VW (avoids a $() subshell per segment)
  local s="$1"               # assign s first; same-line len=${#s} would read s as empty
  local len=${#s} n=0 i=0
  while (( i < len )); do
    if [[ "${s:i:1}" == $'\033' ]]; then
      while (( i < len )) && [[ "${s:i:1}" != m ]]; do (( i++ )); done
      (( i++ ))            # skip the closing 'm'
    else
      (( n++, i++ ))
    fi
  done
  VW=$n
}

parts=()

# ---- working folder + git, posh-git style ----
field '"cwd":"([^"]*)"'; cwd="$F"     # Windows paths contain no quotes, so [^"]* is enough
cwd="${cwd//\\\\/\\}"                 # JSON "\\" -> "\"
leaf="${cwd##*/}"; leaf="${leaf##*\\}"

if [ -n "$cwd" ]; then
  unixcwd="$(cygpath -u "$cwd" 2>/dev/null)"
  [ -z "$unixcwd" ] && unixcwd="$(printf '%s' "$cwd" | sed -e 's#\\#/#g' -e 's#^\([A-Za-z]\):#/\L\1#')"
  cd "$unixcwd" 2>/dev/null
fi

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -n "$branch" ]; then
  iA=0; iM=0; iD=0; wA=0; wM=0; wD=0; ahead=0; behind=0
  while IFS= read -r ln; do
    if [[ "$ln" == '## '* ]]; then
      [[ "$ln" =~ ahead\ ([0-9]+) ]]  && ahead=${BASH_REMATCH[1]}
      [[ "$ln" =~ behind\ ([0-9]+) ]] && behind=${BASH_REMATCH[1]}
      continue
    fi
    [ ${#ln} -lt 2 ] && continue
    x="${ln:0:1}"; y="${ln:1:1}"
    if [ "$x" = '?' ] && [ "$y" = '?' ]; then wA=$((wA+1)); continue; fi
    case "$x" in A) iA=$((iA+1));; M|R|C) iM=$((iM+1));; D) iD=$((iD+1));; esac
    case "$y" in A) wA=$((wA+1));; M) wM=$((wM+1));; D) wD=$((wD+1));; esac
  done < <(git status --porcelain=v1 --branch 2>/dev/null)

  sync=""
  [ "$ahead" -gt 0 ]  && sync+="${E}[${ACCENT}m^${ahead}${E}[0m"
  [ "$behind" -gt 0 ] && sync+="${E}[${ACCENT}mv${behind}${E}[0m"

  staged=""; work=""
  [ $((iA+iM+iD)) -gt 0 ] && staged="${E}[32m+${iA} ~${iM} -${iD}${E}[0m"
  [ $((wA+wM+wD)) -gt 0 ] && work="${E}[31m+${wA} ~${wM} -${wD}${E}[0m"
  if [ -n "$staged" ] && [ -n "$work" ]; then
    counts="${staged}${E}[${ACCENT}m | ${E}[0m${work}"
  else
    counts="${staged}${work}"
  fi

  flag=""
  if   [ $((wA+wM+wD)) -gt 0 ]; then flag="${E}[31m!${E}[0m"
  elif [ $((iA+iM+iD)) -gt 0 ]; then flag="${E}[32m~${E}[0m"
  elif [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then flag="${E}[32m=${E}[0m"
  fi

  inside=""
  for seg in "$sync" "$counts" "$flag"; do
    [ -n "$seg" ] && { [ -n "$inside" ] && inside+=" "; inside+="$seg"; }
  done
  bracket="${E}[35m${branch}${E}[0m"
  [ -n "$inside" ] && bracket+=" $inside"
  gitstr="${E}[${ACCENT}m[${E}[0m${bracket}${E}[${ACCENT}m]${E}[0m"
else
  gitstr="${E}[${ACCENT}m[no git]${E}[0m"
fi

if [ -n "$leaf" ]; then
  parts+=("${E}[${ACCENT}m>> ${E}[0m${E}[33m${leaf}${E}[0m $gitstr")
else
  parts+=("$gitstr")
fi

# ---- provider detection (model name decides Claude vs DeepSeek path) ----
field '"display_name":"([^"]*)"'; model="$F"
is_ds=0
[[ "${model,,}" == *deepseek* ]] && is_ds=1

# ---- context window ----
# used_percentage belongs to context_window iff it's the one followed by "remaining_percentage"
# (rate_limits also has used_percentage); null early in a session -> no match -> ctx hidden.
field '"used_percentage":([0-9.]+),"remaining_percentage"'; ctx="$F"
if [ -n "$ctx" ]; then
  printf -v used '%.0f' "$ctx"
  field '"context_window":[{][^}]*"total_input_tokens":([0-9.]+)'; printf -v tokK '%.0f' "${F:-0}"; tokK=$(( tokK / 1000 ))
  if [ "$is_ds" -eq 1 ]; then
    # DeepSeek: override context size by model (JSON may report wrong value)
    if [[ "${model,,}" == *deepseek-v4-flash* ]]; then
      sizeK=200   # v4-flash: 200K
    else
      sizeK=1000  # default DeepSeek: 1M
    fi
    # recalculate percentage based on real window size (JSON % is based on wrong size)
    if [ "$sizeK" -gt 0 ]; then
      used=$(awk "BEGIN {printf \"%.0f\", $tokK / $sizeK * 100}")
    fi
  else
    field '"context_window":[{][^}]*"context_window_size":([0-9.]+)'; printf -v sizeK '%.0f' "${F:-0}"; sizeK=$(( sizeK / 1000 ))
  fi
  pctcol "$used" 36
  parts+=("${E}[${ACCENT}mctx ${E}[0m${E}[${PC}m${used}%${E}[0m${E}[${ACCENT}m (${tokK}k/${sizeK}k)${E}[0m")
fi

# ---- usage / quota: 5h (reset clock) + 7d (Anthropic-only; hidden for DeepSeek) ----
if [ "$is_ds" -eq 0 ]; then
field '"five_hour":[{][^}]*"used_percentage":([0-9.]+)'; h5="$F"
field '"seven_day":[{][^}]*"used_percentage":([0-9.]+)'; d7="$F"
usg=""
if [ -n "$h5" ]; then
  printf -v h5r '%.0f' "$h5"
  pctcol "$h5r"
  usg="${E}[${ACCENT}musg 5h ${E}[0m${E}[${PC}m${h5r}%${E}[0m"
  field '"five_hour":[{][^}]*"resets_at":([0-9]+)'; resets="$F"
  if [ -n "$resets" ]; then
    printf -v clock '%(%H:%M)T' "$resets"   # epoch -> local HH:MM, no `date` fork
    [ -n "$clock" ] && usg+="${E}[${ACCENT}m @${clock}${E}[0m"
  fi
fi
if [ -n "$d7" ]; then
  printf -v d7r '%.0f' "$d7"
  if [ "$d7r" -ge 90 ]; then c7="$HOT"; else c7="$ACCENT"; fi
  [ -z "$usg" ] && usg="${E}[${ACCENT}musg ${E}[0m"
  usg+="${E}[${ACCENT}m (7d ${E}[0m${E}[${c7}m${d7r}%${E}[0m${E}[${ACCENT}m)${E}[0m"
fi
[ -n "$usg" ] && parts+=("$usg")
fi   # end of Anthropic-only quota block

# ---- DeepSeek balance (cached 5min, async bg refresh) ----
if [ "$is_ds" -eq 1 ]; then
  cache="$HOME/.claude/.poshline-balance"
  now=$(date +%s)
  bal=""; cache_fresh=0
  if [ -f "$cache" ]; then
    cache_ts=$(head -1 "$cache" 2>/dev/null)
    [ -n "$cache_ts" ] && [ $(( now - cache_ts )) -lt 300 ] && cache_fresh=1
    bal=$(tail -1 "$cache" 2>/dev/null)
  fi
  # bg refresh if stale and API key is in env (set by ccswitch via Claude Code settings.json)
  if [ "$cache_fresh" -eq 0 ] && [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    lock="$HOME/.claude/.poshline-balance.lock"
    skip=0
    if [ -f "$lock" ]; then
      lock_ts=$(head -1 "$lock" 2>/dev/null)
      [ -n "$lock_ts" ] && [ $(( now - lock_ts )) -lt 30 ] && skip=1
    fi
    if [ "$skip" -eq 0 ]; then
      printf '%s\n' "$now" > "$lock"
      ( now="$now"; token="$ANTHROPIC_AUTH_TOKEN"; cache="$cache"; lock="$lock"
        resp=$(curl -sL -m 5 -H "Authorization: Bearer $token" -H "Accept: application/json" "https://api.deepseek.com/user/balance" 2>/dev/null)
        bal_val=$(printf '%s' "$resp" | grep -o '"total_balance":"[^"]*"' | head -1 | grep -o '[0-9.]*')
        if [ -n "$bal_val" ]; then
          printf '%s\n%s\n' "$now" "$bal_val" > "$cache.tmp" && mv "$cache.tmp" "$cache"
        fi
        rm -f "$lock"
      ) &
    fi
  fi
  if [ -n "$bal" ]; then
    parts+=("${E}[${ACCENT}mbal ¥${E}[0m${E}[32m${bal}${E}[0m")
  fi
fi

# ---- model (+ effort level for Claude only), pushed last so it shows at the end of the bar ----
if [ -n "$model" ]; then
  if [ "$is_ds" -eq 1 ]; then
    m="${E}[38;2;150;166;246m${model}${E}[0m"        # #96a6f6 for DeepSeek
  else
    m="${E}[36m${model}${E}[0m"                    # cyan for Claude
    field '"effort":[{]"level":"([^"]*)"'; effort="$F"
    [ -n "$effort" ] && m+="${E}[${ACCENT}m ${effort}${E}[0m"
  fi
  parts+=("$m")
fi

# ---- join with " | "; wrap to new lines when too narrow to fit one row ----
# Claude Code sets $COLUMNS to the terminal width (v2.1.153+). Pack segments greedily:
# keep each segment whole, start a new line once the next one would overflow.
sep="${E}[${ACCENT}m | ${E}[0m"
avail=$(( ${COLUMNS:-80} - 2 ))   # -2 leaves room for padding so the row never clips
[ "$avail" -lt 20 ] && avail=20
sepw=3                            # visible width of " | "

out=""; curw=0
for p in "${parts[@]}"; do
  vwidth "$p"; pw=$VW
  if [ -z "$out" ]; then
    out="$p"; curw=$pw
  elif [ $(( curw + sepw + pw )) -le "$avail" ]; then
    out+="$sep$p"; curw=$(( curw + sepw + pw ))
  else
    out+=$'\n'"$p"; curw=$pw   # wrap: this segment starts a fresh line
  fi
done
printf '%s' "$out"
