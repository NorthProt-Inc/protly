#!/usr/bin/env python3
"""Summarize a walk-back probe run folder: checks.txt (walk-* lines) and keyboard-log.txt (walk/wb/wr/wf lines).

Usage: analyze.py <dir with checks.txt and keyboard-log.txt>
"""
import collections
import re
import sys

d = sys.argv[1]
checks = open(f"{d}/checks.txt", encoding="utf-8").read().splitlines()
log = open(f"{d}/keyboard-log.txt", encoding="utf-8", errors="replace").read().splitlines()

print("== CHECK lines (walk-*)")
for line in checks:
    if not line.startswith("CHECK walk-"):
        continue
    m = re.match(r"CHECK (\S+) (\S+) (.*)", line)
    cid, status, ev = m.groups()
    print(f"{cid} {status}")
    for t in re.findall(r"t(\d+)=\{(.*?)\}(?= t\d+=\{|$)", ev):
        n, body = t
        real = re.search(r"real=(\S+)", body)
        sel = re.search(r" sel=(\S+)", body)
        carried = re.search(r'carried="(.*?)"(?= )', body)
        verdict = re.search(r'" (whole=.*?) s=', body)
        secs = re.search(r" s=([\d.]+)", body)
        selafter = re.search(r"selafter=(\S+)", body)
        left = re.search(r"left=(\S+)", body)
        out = re.search(r"outcome=(\S+)", body)
        c = carried.group(1) if carried else ""
        note = c.split(" | ", 1)[1] if " | " in c else c
        print(f"  t{n}: real={real.group(1) if real else '?'} sel={sel.group(1) if sel else '?'} s={secs.group(1) if secs else '?'}"
              f" selafter={selafter.group(1) if selafter else '?'} left={left.group(1) if left else '?'}"
              f" {('outcome=' + out.group(1)) if out else ''}")
        print(f"      verdict: {verdict.group(1) if verdict else '?'}")
        print(f"      read: {c.split(' | ')[0][:60]}")
        print(f"      walk: {note}")

print()
print("== keyboard log: walk summaries")
pat = re.compile(r"\[com\.northprot\.protly:read\] (.*)$")
lines = [m.group(1) for m in (pat.search(l) for l in log) if m]
for l in lines:
    if l.startswith(("walk start", "walk collapse", "walk base", "walk whole")) or " done " in l or l.startswith("wr ") \
            or re.match(r"wb \S+ (start|stuck)", l) or re.match(r"wf \S+ (end|stuck)", l):
        print(" ", l[:330])

print()
print("== unit steps over a line feed (lf>0) and odd steps")
odd = collections.Counter()
for l in lines:
    if l.startswith("wb unit s="):
        f = dict(re.findall(r"(\w+)=(\S+)", l))
        key = f"lf={f.get('lf')} polls={f.get('polls')} front={f.get('front')} cons={f.get('cons')} aok={f.get('aok')} fs={f.get('fs')}"
        odd[key] += 1
for k, v in odd.most_common(40):
    print(f"  {v:5d}  {k}")

print()
print("== jump/jump1 steps: polls, ms, front, late, lf")
jc = collections.Counter()
for l in lines:
    m = re.match(r"wb (jump1?) s=", l)
    if m:
        f = dict(re.findall(r"(\w+)=(\S+)", l))
        jc[f"{m.group(1)} polls={f.get('polls')} late={f.get('late')} cons={f.get('cons')} aok={f.get('aok')} fs={f.get('fs')}"] += 1
for k, v in sorted(jc.items()):
    print(f"  {v:5d}  {k}")
