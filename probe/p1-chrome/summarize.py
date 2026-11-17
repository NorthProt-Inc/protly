"""Summarize harness.cjs JSONL runs: one row per (surface, trigger, lineMode, cursor, n, ime).
Usage: python3 -I probe/p1-chrome/summarize.py <run.jsonl>... [--by surface,trigger,lineMode]
Columns: trials; typedOk (the box held every typed line before the trigger); call (an API call went out);
sentAll (the API got every typed line, exact nonblank lines); domOk (the box ends holding the translation's
nonblank lines in order); modelOk (the editor's own model does: what the site would send); koLeft (Hangul left in
the box); lastKo (the last user line is Hangul); ui (protly card/toast outcomes, counted)."""
import json
import sys
from collections import Counter, defaultdict

args = [a for a in sys.argv[1:] if not a.startswith('--')]
by = 'surface,trigger,lineMode,cursor,n,ime'
for a in sys.argv[1:]:
    if a.startswith('--by='):
        by = a[5:]
keys = by.split(',')
rows = defaultdict(list)
for f in args:
    for line in open(f, encoding='utf-8'):
        r = json.loads(line)
        rows[tuple(str(r.get(k)) for k in keys)].append(r)


def frac(rs, pred):
    n = sum(1 for r in rs if pred(r))
    return f'{n}/{len(rs)}'


print('\t'.join(keys + ['trials', 'typedOk', 'call', 'sentAll', 'domOk', 'modelOk', 'koLeft', 'lastKo', 'ui']))
for k in sorted(rows):
    rs = rows[k]
    ui = Counter(r.get('ui') for r in rs)
    print('\t'.join(list(k) + [
        str(len(rs)),
        frac(rs, lambda r: r.get('before', {}).get('typedOk')),
        frac(rs, lambda r: r.get('calls', 0) > 0),
        frac(rs, lambda r: r.get('sent', {}).get('sameNonblank')),
        frac(rs, lambda r: r.get('after', {}).get('domNonblankEq')),
        frac(rs, lambda r: r.get('after', {}).get('modelNonblankEq')),
        frac(rs, lambda r: r.get('after', {}).get('domHangul')),
        frac(rs, lambda r: r.get('after', {}).get('domLastUserLineHangul')),
        ';'.join(f'{u}={c}' for u, c in ui.most_common()),
    ]))
