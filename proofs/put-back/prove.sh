#!/bin/bash
# Living proof: which ways of moving items to the Trash leave macOS's Put Back
# record, under one declared Finder state. README.md beside it is the thesis,
# the sources and every result so far.
#
#   proofs/put-back/prove.sh closed   Finder shows no window on the Trash
#   proofs/put-back/prove.sh open     Finder shows the Trash in a window
#
# Needs Full Disk Access for the terminal (it reads ~/.Trash/.DS_Store), the
# Xcode command line tools (swiftc, python3) and about four minutes. It moves
# 18 small scratch files named pbproof-* into your Trash and leaves them there:
# it never deletes anything in the Trash. Exit 0: every case matched what is
# known; 1: something changed (the run says what); 64: a wrong call or the
# Finder state is not the one declared.
set -euo pipefail

state="${1:-}"
[[ "$state" == closed || "$state" == open ]] || {
    echo "usage: prove.sh closed|open"
    exit 64
}
here="$(cd "$(dirname "$0")" && pwd)"
store="$HOME/.Trash/.DS_Store"
settle=180

# Finder's windows, as the folders they show; never touched, only read.
windows() {
    osascript -e 'tell application "Finder"
        set out to ""
        repeat with w in every Finder window
            set out to out & POSIX path of (target of w as alias) & linefeed
        end repeat
        return out
    end tell'
}
trash_shown() { windows | grep -qx "$HOME/.Trash/"; }
assert_state() {
    if trash_shown; then now=open; else now=closed; fi
    if [[ "$now" != "$state" ]]; then
        echo "Finder's Trash window is $now $1, and this run was declared $state."
        echo "Finder shows: $(windows | tr '\n' ' ')"
        exit 64
    fi
}

head -c 1 "$store" >/dev/null 2>&1 || {
    echo "cannot read $store: give this terminal Full Disk Access"
    exit 64
}
assert_state "before the run"

work="$(mktemp -d /tmp/pbproof.XXXXXX)"
probe="$work/probe"
xcrun swiftc -O "$here/probe.swift" -o "$probe"
run="$(date +%H%M%S)"
mk() { for n in 1 2 3; do echo x >"$work/pbproof-$1-$n-$run.txt"; done; }
files() { for n in 1 2 3; do echo "$work/pbproof-$1-$n-$run.txt"; done; }

echo "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), Finder $(mdls -raw -name kMDItemVersion /System/Library/CoreServices/Finder.app), Trash window $state, run $run"
echo "Finder shows: $(windows | tr '\n' ' ')"

# The watch: twice a second, for the whole run, what Finder shows and how many
# of this run's items are in the Trash. A person opening or closing a window,
# or emptying the Trash, mid-run would change what is measured: the run is
# then void and says what happened, never a verdict.
watchlog="$work/watch"
(
    while :; do
        printf '%s|%s|%s\n' "$(date +%H:%M:%S)" "$(windows | tr '\n' ' ')" \
            "$(ls -1 "$HOME/.Trash" 2>/dev/null | grep -c "pbproof-.*-$run.txt" || true)"
        perl -e 'select(undef, undef, undef, 0.5)'
    done
) >"$watchlog" &
watcher=$!
disown $watcher
trap 'kill $watcher 2>/dev/null || true' EXIT

# Each case moves three fresh files; the name a file had is the name it has
# in the Trash (no collision: the run's time is in every name).
mk api-each;  for f in $(files api-each); do "$probe" 0 "$f" >/dev/null; done
mk api-one;   "$probe" 0 $(files api-one) >/dev/null
mk api-half;  "$probe" 0.5 $(files api-half) >/dev/null
mk api-two5;  "$probe" 2.5 $(files api-two5) >/dev/null
mk apple-each; for f in $(files apple-each); do /usr/bin/trash "$f"; done
mk apple-one; /usr/bin/trash $(files apple-one)
assert_state "after the moves"

# A record is the item's name in the Trash (UTF-16BE, length-prefixed) then
# the code ptbL: the bytes of the record itself inside the store's B-tree, so
# a match is a record and a miss is no record. trash's own reader
# (Sources/TrashKit) is not used here: this is what it is checked against.
records() {
    python3 -I - "$store" "$run" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
for case in ['api-each', 'api-one', 'api-half', 'api-two5', 'apple-each', 'apple-one']:
    marks = ''
    for n in '123':
        name = f'pbproof-{case}-{n}-{sys.argv[2]}.txt'
        key = struct.pack('>I', len(name)) + name.encode('utf-16-be') + b'ptbL'
        marks += 'Y' if key in data else '.'
    print(case, marks)
EOF
}

perl -e 'select(undef, undef, undef, 10)'
early="$(records)"
perl -e "select(undef, undef, undef, $settle - 10)"
assert_state "after waiting"
final="$(records)"
kill $watcher 2>/dev/null || true

# Void unless Finder showed the same folders all along and, once the 18 items
# were in, the Trash kept all 18.
shown="$(cut -d'|' -f2 "$watchlog" | sort -u)"
if [[ "$(wc -l <<<"$shown")" -gt 1 ]]; then
    echo "VOID: Finder's windows changed during the run:"
    awk -F'|' 'prev != $2 { print "  " $1 "  " $2 } { prev = $2 }' "$watchlog"
    exit 64
fi
if awk -F'|' '$3 == 18 { full = 1 } full && $3 < 18 { bad = 1 } END { exit !bad }' "$watchlog"; then
    echo "VOID: items of this run left the Trash during it (emptied or put back):"
    awk -F'|' 'prev != $3 { print "  " $1 "  " $3 " of 18 in the Trash" } { prev = $3 }' "$watchlog"
    exit 64
fi
echo "watched: Finder showed [$shown] throughout; all 18 items stayed in the Trash"

# What is known, per Finder state (README.md: Results). A case with no
# expectation is recorded, not judged.
expect() {
    case "$state:$1" in
    closed:api-each) echo YYY ;;
    closed:api-one) echo Y.. ;;
    closed:api-half) echo Y.. ;;
    closed:api-two5) echo YYY ;;
    closed:apple-each) echo YYY ;;
    closed:apple-one) echo Y.. ;;
    *) echo "" ;;
    esac
}

changed=0
printf '%-11s %-6s %-6s %-9s %s\n' case "+10 s" "+${settle} s" expected verdict
while read -r case marks; do
    was="$(grep "^$case " <<<"$early" | cut -d' ' -f2)"
    want="$(expect "$case")"
    if [[ -z "$want" ]]; then
        verdict="recorded (nothing known yet)"
    elif [[ "$marks" == "$want" ]]; then
        verdict=holds
    else
        verdict="CHANGED"
        changed=1
    fi
    printf '%-11s %-6s %-6s %-9s %s\n' "$case" "$was" "$marks" "${want:--}" "$verdict"
done <<<"$final"

/usr/bin/trash "$work"
exit $changed
