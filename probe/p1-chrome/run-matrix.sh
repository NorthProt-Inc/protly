#!/bin/bash
# The P1 matrix as run on 2026-11-17. Usage: probe/p1-chrome/run-matrix.sh <out-dir> <bundle> '<surfaces json>' <tag>
# 1) every line mode at cursor end, 3 and 5 lines, 10 repeats; 2) cursor middle and selection on 5 lines, 10 repeats;
# 3) IME: last syllable still composing when the trigger arrives (cursor end), 10 repeats;
# 4) timing: reply after 0 ms and 1500 ms, 5 lines, 10 repeats.
set -u
cd "$(dirname "$0")/../.."
OUT=$1; BUNDLE=$2; SURF=$3; TAG=$4; TRIG=${5:-}
H="node probe/p1-chrome/harness.cjs $PWD $BUNDLE $OUT/$TAG.jsonl"
$H "{\"reps\":10,\"n\":[3,5],\"lineMode\":[\"para\",\"blank\",\"paste\",\"trail\"],\"cursor\":[\"end\"],\"ime\":[false],\"delay\":[150],\"surfaces\":$SURF$TRIG}"
$H "{\"reps\":10,\"n\":[5],\"lineMode\":[\"para\"],\"cursor\":[\"middle\",\"selection\"],\"ime\":[false],\"delay\":[150],\"surfaces\":$SURF$TRIG}"
$H "{\"reps\":10,\"n\":[3,5],\"lineMode\":[\"para\"],\"cursor\":[\"end\"],\"ime\":[true],\"delay\":[150],\"surfaces\":$SURF$TRIG}"
$H "{\"reps\":10,\"n\":[5],\"lineMode\":[\"para\"],\"cursor\":[\"end\"],\"ime\":[false],\"delay\":[0,1500],\"surfaces\":$SURF$TRIG}"
