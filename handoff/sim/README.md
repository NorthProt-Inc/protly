# FakeProxy simulator (Linux, not evidence about real hosts)

Type-checks `ios-app/Sources/ProtlyKeyboard/FieldText.swift` against small UIKit and os shims and drives it on a
fake windowed proxy (deterministic before-context window of 40-300 units per position, after-context up to the next
line feed, moves applied 5-30 ms late; `byChars` models WebKit moving by characters; `blankChance` empty
before-contexts; `dropDeletes` deletes that never apply).

Set up (symlinks, so it builds against the repo):

    S=<scratch dir>; mkdir -p $S && cp -r handoff/sim/* $S/
    ln -s $PWD/ios-app/ProtlyCore/Sources/ProtlyCore $S/Sources/ProtlyCore
    ln -s $PWD/ios-app/Sources/ProtlyKeyboard/FieldText.swift $S/Sources/sim/FieldText.swift
    cd $S && swift build && ./.build/debug/sim

`last-run.txt`: the output for the working tree committed with it (11 PASS). It logs lengths, hashes, timings only.
