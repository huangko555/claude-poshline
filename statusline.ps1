# Claude Code statusLine (left-aligned)
#   git <branch> [posh-git status]  |  model  |  context  |  usg <quota>
# Receives the session JSON on stdin.
$ErrorActionPreference = 'SilentlyContinue'

# read session JSON from stdin.
# NOTE: if the bar shows only "[no git]" with a non-ASCII (e.g. Chinese) working dir, it's the
# console code page (936) mis-decoding the UTF-8 stdin so ConvertFrom-Json fails. Fix is to run
# with the UTF-8 code page (65001) -- run under pwsh 7 and/or enable system-wide UTF-8.
$raw = $input | Out-String
$d = $raw | ConvertFrom-Json

$ESC = [char]27
function C($code, $text) { "$ESC[${code}m$text$ESC[0m" }
# bright "bypass permissions" style red + amber warn tier (truecolor). tweak R;G;B to taste.
$HOT  = '38;2;255;92;87'
$WARN = '38;2;255;138;60'
# tiers: >=90 red, >=70 amber, else default. caller picks default: ctx=cyan(36), usg=green(32)
function PctColor($p, $def = '32') { if ($p -ge 90) { $HOT } elseif ($p -ge 70) { $WARN } else { $def } }

# muted gray for labels / separators (between the too-dim ANSI dim and the loud orange).
# truecolor; tweak the R;G;B here for a lighter/darker gray.
$ACCENT = '38;2;160;160;160'

$parts = @()

# ---- working folder + git, posh-git style:  <folder> [<branch> <status>] ----
$leaf = ''
if ($d.cwd) {
    $leaf = Split-Path $d.cwd -Leaf
    if (-not $leaf) { $leaf = $d.cwd }          # e.g. a drive root like C:\
}
$branch = $d.workspace.git_worktree
if ($d.cwd) { Push-Location $d.cwd }
if (-not $branch) { $branch = (git rev-parse --abbrev-ref HEAD 2>$null) }
if ($branch) {
    $iA=0; $iM=0; $iD=0; $wA=0; $wM=0; $wD=0; $ahead=0; $behind=0
    foreach ($ln in (git status --porcelain=v1 --branch 2>$null)) {
        if ($ln.StartsWith('## ')) {
            if ($ln -match '\[ahead (\d+)')  { $ahead  = [int]$Matches[1] }
            if ($ln -match 'behind (\d+)')   { $behind = [int]$Matches[1] }
            continue
        }
        if ($ln.Length -lt 2) { continue }
        $x = $ln[0]; $y = $ln[1]
        if ($x -eq '?' -and $y -eq '?') { $wA++; continue }   # untracked
        switch ($x) { 'A'{$iA++} 'M'{$iM++} 'R'{$iM++} 'C'{$iM++} 'D'{$iD++} }   # staged/index
        switch ($y) { 'A'{$wA++} 'M'{$wM++} 'D'{$wD++} }                          # working tree
    }

    # sync (ahead/behind remote) -- ASCII so it renders in any font
    $sync = ''
    if ($ahead  -gt 0) { $sync += C $ACCENT "^$ahead" }   # ahead
    if ($behind -gt 0) { $sync += C $ACCENT "v$behind" }  # behind

    # change counts: staged (green) and working (red), posh-git separates with " | "
    $grp = @()
    if (($iA+$iM+$iD) -gt 0) { $grp += C '32' ("+{0} ~{1} -{2}" -f $iA,$iM,$iD) }
    if (($wA+$wM+$wD) -gt 0) { $grp += C '31' ("+{0} ~{1} -{2}" -f $wA,$wM,$wD) }
    $counts = $grp -join (C $ACCENT ' | ')

    # trailing state flag
    $flag = ''
    if     (($wA+$wM+$wD) -gt 0) { $flag = C '31' '!' }       # working tree dirty
    elseif (($iA+$iM+$iD) -gt 0) { $flag = C '32' '~' }       # staged only
    elseif ($ahead -eq 0 -and $behind -eq 0) { $flag = C '32' '=' }  # clean & synced

    # posh-git: branch + status all inside one bracket
    $inside = (@($sync, $counts, $flag) | Where-Object { $_ }) -join ' '
    $bracket = (C '35' $branch)
    if ($inside) { $bracket += ' ' + $inside }
    $gitStr = (C $ACCENT '[') + $bracket + (C $ACCENT ']')
} else {
    $gitStr = (C $ACCENT '[no git]')        # not a git repo
}
if ($d.cwd) { Pop-Location }
# ">> " prefix + folder name (yellow) + space + bracketed git status, posh-git style
if ($leaf) { $parts += (C $ACCENT '>> ') + (C '33' $leaf) + ' ' + $gitStr } else { $parts += $gitStr }

# ---- model (+ effort level appended in gray) ----
if ($d.model.display_name) {
    $m = C '36' $d.model.display_name                # cyan
    if ($d.effort.level) { $m += C $ACCENT " $($d.effort.level)" }   # e.g. "high"
    $modelPart = $m   # pushed last (after usg) so model shows at the end of the bar
}

# ---- conversation context ----
$cw = $d.context_window
if ($cw -and $null -ne $cw.used_percentage) {
    $used  = [math]::Round([double]$cw.used_percentage)
    $tokK  = [math]::Round([double]$cw.total_input_tokens / 1000)
    $sizeK = [math]::Round([double]$cw.context_window_size / 1000)
    $col   = PctColor $used 36
    $parts += (C $ACCENT 'ctx ') + (C $col "$used%") + (C $ACCENT " (${tokK}k/${sizeK}k)")
}

# ---- usage / quota: 5h (reset as clock time) + 7d in parentheses, one block ----
# each % colors by its own value: 5h green (red >=80), 7d gray (red >=80).
$rl = $d.rate_limits
if ($rl) {
    $u = ''
    $hasUsg = $false
    if ($rl.five_hour -and $null -ne $rl.five_hour.used_percentage) {
        $h5 = [math]::Round([double]$rl.five_hour.used_percentage)
        $c5 = PctColor $h5
        $u  = (C $ACCENT 'usg 5h ') + (C $c5 "$h5%")
        if ($rl.five_hour.resets_at) {
            $clock = [DateTimeOffset]::FromUnixTimeSeconds([long]$rl.five_hour.resets_at).LocalDateTime.ToString('HH:mm')
            $u += C $ACCENT " @$clock"
        }
        $hasUsg = $true
    }
    if ($rl.seven_day -and $null -ne $rl.seven_day.used_percentage) {
        $d7 = [math]::Round([double]$rl.seven_day.used_percentage)
        $c7 = if ($d7 -ge 90) { $HOT } else { $ACCENT }   # 7d: gray default, red >=90
        if (-not $hasUsg) { $u = (C $ACCENT 'usg '); $hasUsg = $true }
        $u += (C $ACCENT ' (7d ') + (C $c7 "$d7%") + (C $ACCENT ')')
    }
    if ($hasUsg) { $parts += $u }
}

if ($modelPart) { $parts += $modelPart }
($parts -join (C $ACCENT ' | '))
