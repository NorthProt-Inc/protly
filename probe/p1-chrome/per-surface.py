"""Per-surface raw counts for chrome.md. Usage: python3 -I probe/p1-chrome/per-surface.py <run.jsonl>...
read: typedOk (box held every typed line), sentExact (API draft == typed text exactly), sentLines (same nonblank
lines), lost (typed lines missing from the API draft, summed); write: domExact (box text == translation exactly),
domLines (same nonblank lines in order; Gmail always fails it because the signature/quote lines are in the box),
model (editor model same nonblank lines), koLeft (Hangul left in the box), partial (the 10 ms timeline saw the
translation's markers and Hangul at once: a part-written box), shrunk (box ends with fewer lines than before the
trigger and holds Hangul: the original came back with its line breaks gone)."""
import json
import re
import sys
from collections import Counter, defaultdict

rows = defaultdict(list)
for f in sys.argv[1:]:
    for line in open(f, encoding='utf-8'):
        r = json.loads(line)
        rows[(r['surface'], r['trigger'], 'multi' if r['n'] > 1 else 'single')].append(r)


def g(r, a, b):
    return (r.get(a) or {}).get(b)


print('surface\ttrigger\tlines\ttrials\ttypedOk\tsentExact\tsentLines\tlost\tdomExact\tdomLines\tmodel\tkoLeft\tpartial\tshrunk\tui')
for k in sorted(rows):
    rs = rows[k]

    def cnt(p):
        return sum(1 for r in rs if p(r))

    partial = cnt(lambda r: any(re.search(r'/([1-9]\d*)M/H', t) for t in (r.get('timeline') or [])))
    shrunk = cnt(lambda r: g(r, 'after', 'domHangul') and g(r, 'after', 'domLines') is not None
                 and g(r, 'after', 'domLines') < g(r, 'before', 'domLines'))
    ui = Counter(r.get('ui') for r in rs)
    print('\t'.join(map(str, [*k, len(rs),
        cnt(lambda r: g(r, 'before', 'typedOk')), cnt(lambda r: g(r, 'sent', 'exactTyped')),
        cnt(lambda r: g(r, 'sent', 'sameNonblank')), sum((g(r, 'sent', 'lostLines') or 0) for r in rs),
        cnt(lambda r: g(r, 'after', 'domExact')), cnt(lambda r: g(r, 'after', 'domNonblankEq')),
        cnt(lambda r: g(r, 'after', 'modelNonblankEq')), cnt(lambda r: g(r, 'after', 'domHangul')), partial, shrunk,
        ';'.join(f'{u}={c}' for u, c in ui.most_common())])))
