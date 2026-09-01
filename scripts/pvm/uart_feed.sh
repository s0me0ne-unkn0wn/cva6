#!/bin/bash
# uart_feed.sh <uart_log> [tty] -- feed the B4 console script into the PVM guest.
L=${1:?uart log}; T=${2:-/dev/ttyUSB0}
wait_for() { local d=${2:-600}; local i=0; until grep -qa "$1" "$L" 2>/dev/null; do sleep 1; i=$((i+1)); [ $i -ge $d ] && { echo "FEED timeout on '$1'"; exit 1; }; done; }
snd() { sleep 0.4; printf '%s\r' "$1" >&3; echo "FEED sent: $1"; }
exec 3>"$T"
wait_for "B4 rx: type"
snd "hello-pvm-console"
wait_for "B4 rx: got"
wait_for "starting interactive hush"
sleep 6
snd "uname -m"
sleep 3; snd 'echo guest math: $((6*7))'
sleep 3; snd "cat /etc/motd"
sleep 4; snd "exit"
wait_for "launcher: done"
echo "FEED done"
