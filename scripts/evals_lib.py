#!/usr/bin/env python3
"""Shared helpers of the phase-6 classification evals (run-evals.py, score-evals.py).

  evals_lib.py make-truth [--sample evals/sample-tiers.md] [--out evals/truth.json] [--check]
      Derive evals/truth.json (machine-readable ground truth) from evals/sample-tiers.md. --check writes nothing and exits 1
      when the file on disk differs from what the sample file says. truth.json is an answer key like sample-tiers.md: only the
      runner and the scorer read it, never a ticket session.

Inputs for the sessions are copied verbatim from their sources, never from evals/: WL-01..06 = the section of
capstone/tickets.md; Retro #N = "Retro #N - <item>" with the Item cell of the day-15.md table (no label, no evidence column,
the same shape as the dry runs). The fixtures (goal / ACs for the stop (DoR) rows) are the only text taken from the sample file.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SAMPLE = os.path.join(SKILL, "evals", "sample-tiers.md")
TRUTH = os.path.join(SKILL, "evals", "truth.json")
RANK = {"A": 0, "B": 1, "C": 2}
# row 14 is the only split row; its parts come from the "Tier" cell "hook part C, skills B"
SPLIT_PARTS = [("env-check skill", "skills"), ("Stop hook", "hook"), ("verify-report skill", "skills")]


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def parse_sample_tiers(text):
    rows, fixtures, section = [], {}, None
    for line in text.splitlines():
        if line.startswith("## "):
            section = "fixtures" if "fixtures" in line.lower() else "other"
            continue
        if not line.startswith("|") or re.match(r"^\|[\s|:-]+$", line):
            continue
        c = cells(line)
        if c[0] == "#":
            continue
        if section == "fixtures":
            fixtures[int(c[0])] = parse_fixture(c[2], c[3])
        elif len(c) == 7 and c[0].isdigit():
            rows.append(parse_row(c))
    for r in rows:
        r["fixture"] = fixtures.get(r["row"])
        if r["intake"] == "stop (DoR)" and not r["fixture"]:
            raise ValueError("row %d is stop (DoR) but has no fixture" % r["row"])
    if len(rows) != 14:
        raise ValueError("expected 14 rows, found %d" % len(rows))
    return {"version": 1, "source": "evals/sample-tiers.md", "rows": rows}


def parse_row(c):
    n, ticket, source, intake, tier, reason, missing = c
    m = re.match(r"^(WL-\d+)\s+\S+\s+(.*)$", ticket)
    if m:
        tid, title, kind, retro_no = m.group(1), m.group(2), "capstone", None
    else:
        m = re.match(r"^Retro #(\d+)\s+\S+\s+(.*)$", ticket)
        if not m:
            raise ValueError("cannot read ticket cell: %s" % ticket)
        retro_no = int(m.group(1))
        tid, title, kind = "RETRO-%d" % retro_no, m.group(2), "retro"
    row = {"row": int(n), "id": tid, "kind": kind, "retro_no": retro_no, "title": title,
           "source": source.replace("`", ""), "intake": intake, "tier": None, "parts": None,
           "reason": reason, "missing_dor": [], "fixture": None}
    if intake == "split":
        row["parts"] = []
        for name, key in SPLIT_PARTS:
            m = re.search(r"%s part ([ABC])" % key, tier) or re.search(r"%s (?:part )?([ABC])" % key, tier)
            if not m:
                raise ValueError("no tier for %s in: %s" % (name, tier))
            row["parts"].append({"name": name, "tier": m.group(1)})
    else:
        if tier not in RANK:
            raise ValueError("bad tier cell: %s" % tier)
        row["tier"] = tier
    if intake == "stop (DoR)":
        row["missing_dor"] = [x.strip() for x in re.split(r",\s*(?![^()]*\))", missing) if x.strip()]
    return row


def parse_fixture(goal, acs):
    parts = re.split(r"\s*(?=AC\d+:)", acs.strip())
    parts = [p.strip() for p in parts if p.strip()]
    note = None
    last = parts[-1]
    m = re.search(r"\s*Open question \(stays open for the eval\):\s*(.*)$", last)   # the words "for the eval" do not go to a session
    if m:
        parts[-1] = last[:m.start()].strip()
        note = "Open question: " + m.group(1).strip()
    return {"goal": goal, "acs": parts, "note": note}


def load_truth(path=TRUTH):
    with open(path) as f:
        return json.load(f)


def dumps(truth):
    return json.dumps(truth, indent=2, ensure_ascii=False) + "\n"


# ---- inputs for the sessions ------------------------------------------------------------------------------------------

def capstone_section(text, tid):
    """The lines of `## WL-0N - ...` up to the next `## ` heading, trailing blank lines dropped."""
    lines = text.splitlines()
    start = next((i for i, l in enumerate(lines) if re.match(r"^## %s\b" % re.escape(tid), l)), None)
    if start is None:
        raise ValueError("%s not found in tickets.md" % tid)
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[start:end]).rstrip() + "\n"


def retro_item(text, n):
    for l in text.splitlines():
        m = re.match(r"^\|\s*%d\s*\|\s*([^|]*?)\s*\|" % n, l)
        if m and l.count("|") >= 5:
            return m.group(1)
    raise ValueError("retro item %d not found in day-15.md" % n)


def read_notes(notes_dir):
    with open(os.path.join(notes_dir, "capstone", "tickets.md")) as f:
        cap = f.read()
    with open(os.path.join(notes_dir, "day-15.md")) as f:
        d15 = f.read()
    return cap, d15


def intake_text(row, notes_dir):
    """The text after the ticket ID in the first call (title only for retro items, the whole section for WL tickets)."""
    cap, d15 = read_notes(notes_dir)
    if row["kind"] == "capstone":
        return capstone_section(cap, row["id"])
    return "Retro #%d - %s" % (row["retro_no"], retro_item(d15, row["retro_no"]))


def fixture_text(row, notes_dir):
    cap, d15 = read_notes(notes_dir)
    f = row["fixture"]
    out = ["Retro #%d - %s" % (row["retro_no"], retro_item(d15, row["retro_no"])), "", "Goal: " + f["goal"]]
    out += f["acs"]
    if f.get("note"):
        out.append(f["note"])
    return "\n".join(out) + "\n"


def jobs_for(truth, rounds, only=None):
    """Ordered job list: round by round, in row order; a stop (DoR) row has a second job, the fixture re-run."""
    jobs = []
    for rnd in range(1, rounds + 1):
        for row in truth["rows"]:
            if only and row["id"] not in only:
                continue
            jobs.append({"id": "r%d-%s-intake" % (rnd, row["id"]), "round": rnd, "ticket": row["id"], "kind": "intake", "row": row["row"]})
            if row["intake"] == "stop (DoR)":
                jobs.append({"id": "r%d-%s-fixture" % (rnd, row["id"]), "round": rnd, "ticket": row["id"], "kind": "fixture", "row": row["row"]})
    return jobs


PILOT = ["r1-WL-02-intake", "r1-RETRO-5-intake"]


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="evals_lib.py")
    ap.add_argument("cmd", choices=["make-truth"])
    ap.add_argument("--sample", default=SAMPLE)
    ap.add_argument("--out", default=TRUTH)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    with open(a.sample) as f:
        new = dumps(parse_sample_tiers(f.read()))
    if a.check:
        old = open(a.out).read() if os.path.exists(a.out) else None
        if old != new:
            print("%s differs from %s" % (a.out, a.sample)); return 1
        print("%s is up to date" % a.out); return 0
    with open(a.out, "w") as f:
        f.write(new)
    print("wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
