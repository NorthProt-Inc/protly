#!/usr/bin/env python3
"""Summarize a walk-back probe run folder: ui-log.txt (MARK lines), checks.txt (walk-* RECORD lines) and
keyboard-log.txt (walk/wb/wr/wf lines, category `read`). Lengths, counts, hashes and timings only.

Each keyboard read is given to the last MARK (one per try) before it. A MARK with no read, or more than one, is
shown as such. Per try it prints the field's real shape (RECORD), each walk's summary and reason, the return codes,
the forward walks, the final pick, and whether each walked text's hash equals the field's (MATCH).

Usage: analyze.py <run folder> [--steps]   (--steps: also every logged step line of each try)
"""
import collections
import datetime
import re
import sys

d = sys.argv[1]
show_steps = "--steps" in sys.argv


def read(name):
    try:
        return open(f"{d}/{name}", encoding="utf-8", errors="replace").read().splitlines()
    except FileNotFoundError:
        return []


checks = read("checks.txt")
ui = read("ui-log.txt")
log = read("keyboard-log.txt")

marks = []
for line in ui:
    m = re.match(r"MARK (wk-\S+) ([\d.]+)", line)
    if m:
        marks.append((m.group(1), float(m.group(2))))

records = {}
for line in checks:
    m = re.match(r"CHECK (walk-\S+) (\S+) (.*)", line)
    if not m:
        continue
    cid, _status, ev = m.groups()
    for n, body in re.findall(r"t(\d+)=\{(.*?)\}(?= t\d+=\{|$)", ev):
        records[f"wk-{cid[len('walk-'):]}-{n}"] = body

pat = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*\[com\.northprot\.protly:read\] (.*)$")
events = []
for line in log:
    m = pat.match(line)
    if m:
        t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc)
        events.append((t.timestamp(), m.group(2)))

reads = []
cur = None
for t, l in events:
    if l.startswith("walk start"):
        cur = {"t": t, "lines": []}
        reads.append(cur)
    if cur is not None:
        cur["lines"].append(l)
by_try = collections.defaultdict(list)
for r in reads:
    owner = None
    for name, mt in marks:
        if mt <= r["t"] + 0.5:
            owner = name
    by_try[owner].append(r)


def field(body, key):
    m = re.search(r"(?:^| )" + key + r"=(\S+)", body or "")
    return m.group(1) if m else "?"


def first(lines, prefix):
    return next((l for l in lines if l.startswith(prefix)), None)


totals = collections.Counter()
print("== per try")
for name, _mt in marks:
    body = records.get(name, "")
    real = field(body, "real")
    rs = by_try.get(name, [])
    judge = re.search(r"(whole=.*?) s=", body)
    print(f"{name}: real={real} sel={field(body, 'sel')} s={field(body, 's')} selafter={field(body, 'selafter')}"
          f" left={field(body, 'left')} reads={len(rs)}"
          + (f" outcome={field(body, 'outcome')}" if "outcome=" in body else "")
          + (f" judge: {judge.group(1)}" if judge else ""))
    totals["tries"] += 1
    if not rs:
        totals["tries-without-read"] += 1
    real_hash = real.split("/h")[-1] if "/h" in real else None
    for r in rs:
        L = r["lines"]
        for l in L:
            if l.startswith(("walk start", "walk collapse", "walk base")):
                print("   ", l[:200])
        for pol in ("unit", "jump", "jump1"):
            s = first(L, f"wb {pol} done ")
            if not s:
                print(f"    {pol}: no summary")
                continue
            m = re.match(r"wb \S+ done (\d+)/(\d+)/h([0-9a-f]{8})/(\S+) steps=(\d+) ms=(\d+) (.*)", s)
            n, lf, h, why, steps, ms, rest = m.groups()
            ok = "MATCH" if h == real_hash else ""
            wr = first(L, f"wr {pol} ")
            code = re.search(r" (r1|rs|rx) ", wr).group(1) if wr else "-"
            print(f"    {pol:5s} {n}/{lf}/h{h} {why} steps={steps} ms={ms} return={code} {ok}  [{rest[:160]}]")
            totals[f"{pol} reason={why}"] += 1
            if ok:
                totals[f"{pol} match"] += 1
        for tag in ("f", "fj", "fj1"):
            s = first(L, f"wf {tag} done ")
            if s:
                print(f"    wf {tag}: {s.split(' done ', 1)[1][:90]}")
        w = first(L, "walk whole")
        if w:
            m = re.match(r"walk whole (\d+)/(\d+)/h([0-9a-f]{8})", w)
            ok = "MATCH" if m and m.group(3) == real_hash else "no-match"
            print(f"    -> {w}  [{ok}]")
            totals["reads"] += 1
            totals[f"whole {ok}"] += 1
        else:
            print("    -> no walk whole line")
        if show_steps:
            for l in L:
                if re.match(r"(wb|wf|wr) ", l) and " done " not in l:
                    print("       ", l[:220])
if None in by_try:
    print(f"reads before the first MARK: {len(by_try[None])}")

print()
print("== totals")
for k, v in sorted(totals.items()):
    print(f"  {k}: {v}")

print()
print("== unit steps logged (notable ones only): lf, polls, cons, aok, fs")
odd = collections.Counter()
for _t, l in events:
    if l.startswith("wb unit s="):
        f = dict(re.findall(r"(\w+)=(\S+)", l))
        p = f.get("polls")
        odd[f"lf={f.get('lf')} polls={p if p in ('1', '2') else '3+'} cons={f.get('cons')} aok={f.get('aok')}"
            f" fs={f.get('fs')}"] += 1
for k, v in odd.most_common(40):
    print(f"  {v:5d}  {k}")

print()
print("== jump/jump1 steps: polls, late, cons, aok, fs")
jc = collections.Counter()
for _t, l in events:
    m = re.match(r"wb (jump1?) s=", l)
    if m:
        f = dict(re.findall(r"(\w+)=(\S+)", l))
        jc[f"{m.group(1)} polls={f.get('polls')} late={f.get('late')} cons={f.get('cons')} aok={f.get('aok')}"
           f" fs={f.get('fs')}"] += 1
for k, v in sorted(jc.items()):
    print(f"  {v:5d}  {k}")
