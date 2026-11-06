#!/usr/bin/env python3
"""Validate a guard.json. Usage: validate-guard.py <path-to-guard.json>

Exit 0: valid. Exit 1: invalid (every problem printed, one per line).
Exit 2: unreadable / not JSON. The hooks treat an invalid guard.json as
"state exists but can't be read" and block, so init must never leave one behind.
Standard library only.
"""
import json
import re
import sys

STOP_POINTS = ["local", "before-push", "draft-mr", "ready-mr"]
TIERS = ["A", "B", "C"]
# category -> what a value may be: a list of globs, or the string "N/A"
RISK_CATEGORIES = [
    "risk_paths",
    "auth",
    "payment",
    "personal_data",
    "migration",
    "new_dependency",
    "infra_config",
    "per_user_server_api_or_store",
    "ai_agent_side_effects",
]


def is_str_list(v):
    return isinstance(v, list) and all(isinstance(x, str) and x for x in v)


def check(g):
    errs = []

    def need(path, cond, msg):
        if not cond:
            errs.append(f"{path}: {msg}")

    def get(obj, key, path):
        if not isinstance(obj, dict) or key not in obj:
            errs.append(f"{path}.{key}: missing")
            return None
        return obj[key]

    need("version", g.get("version") == 1, "must be 1")
    for k in ("project_key", "repo_root", "base_branch"):
        v = get(g, k, "$")
        need(k, isinstance(v, str) and v != "", "non-empty string required")
    bn = g.get("branch_naming")
    if bn is not None:
        known = {"id", "id-lowercase", "type", "slug"}
        bad = set(re.findall(r"\{([^{}]*)\}", bn)) - known if isinstance(bn, str) else None
        need("branch_naming", isinstance(bn, str) and not bad and ("{id}" in bn or "{id-lowercase}" in bn)
             and not re.search(r"[{}]", re.sub(r"\{(?:id-lowercase|id|type|slug)\}", "", bn)),
             "string with {id} or {id-lowercase} and only the placeholders {id} {id-lowercase} {type} {slug}%s" % ("; unknown: %s" % sorted(bad) if bad else ""))
    if isinstance(g.get("repo_root"), str):
        need("repo_root", g["repo_root"].startswith("/"), "absolute path required")

    r = get(g, "remotes", "$")
    if r is not None:
        need("remotes", isinstance(r, dict), "object required")
        if isinstance(r, dict):
            need("remotes.push", isinstance(r.get("push"), str) or r.get("push") is None,
                 "string, or null when nothing may be pushed")
            need("remotes.allowed", is_str_list(r.get("allowed")),
                 "list of remote names the skill may push to (may be empty)")
            need("remotes.forbidden", is_str_list(r.get("forbidden")),
                 "list of remote names (may be empty)")
            if is_str_list(r.get("allowed")) and is_str_list(r.get("forbidden")):
                both = set(r["allowed"]) & set(r["forbidden"])
                need("remotes", not both, f"in both allowed and forbidden: {sorted(both)}")

    v = get(g, "verify", "$")
    if isinstance(v, dict):
        for k in ("lint", "test", "build"):
            need(f"verify.{k}", v.get(k) is None or isinstance(v.get(k), str),
                 "command string or null")
        need("verify.on_push", is_str_list(v.get("on_push")),
             "list of keys among lint/test/build run by verify-on-push")
        if is_str_list(v.get("on_push")):
            for k in v["on_push"]:
                need("verify.on_push", k in ("lint", "test", "build") and v.get(k),
                     f"'{k}' must be lint/test/build with a command set")
        t = v.get("timeout_sec")
        need("verify.timeout_sec", isinstance(t, int) and 10 <= t <= 1800, "int 10..1800")
    elif v is not None:
        errs.append("verify: object required")

    for k in ("env_files", "allowlist_extra"):
        val = get(g, k, "$")
        if val is not None:
            need(k, is_str_list(val) or val == [], "list of strings (names/paths only)")
    for f in g.get("env_files", []) if isinstance(g.get("env_files"), list) else []:
        need("env_files", isinstance(f, str) and not f.startswith("/") and ".." not in f,
             f"'{f}': relative file name inside the repo required (names only, never contents)")

    inst = g.get("install")
    need("install", inst is None or isinstance(inst, str), "dependency install command or null")

    ports = get(g, "ports", "$")
    if isinstance(ports, dict):
        need("ports.vars", is_str_list(ports.get("vars")), "list of env var names (may be empty)")
        for k in ("base", "step"):
            need(f"ports.{k}", isinstance(ports.get(k), int) and ports[k] > 0, "positive int")
    elif ports is not None:
        errs.append("ports: object required")

    for k, allowed in (("stop_points", STOP_POINTS),):
        sp = get(g, k, "$")
        if isinstance(sp, dict):
            for t in TIERS:
                need(f"{k}.{t}", sp.get(t) in allowed, f"one of {allowed}")
    cg = get(g, "commit_gate", "$")
    if isinstance(cg, dict):
        for t in TIERS:
            need(f"commit_gate.{t}", cg.get(t) in ("batched", "each"),
                 "\"batched\" (no commit in stage 3, one commit gate in stage 7) or \"each\" (ask before every commit)")

    par = get(g, "max_parallel", "$")
    if isinstance(par, dict):
        for k in ("tier_bc", "total"):
            need(f"max_parallel.{k}", isinstance(par.get(k), int) and par[k] >= 1, "int >= 1")

    risk = get(g, "risk", "$")
    if isinstance(risk, dict):
        cats = get(risk, "categories", "risk")
        if isinstance(cats, dict):
            for c in RISK_CATEGORIES:
                val = cats.get(c)
                need(f"risk.categories.{c}", val == "N/A" or is_str_list(val) or val == [],
                     "list of globs, [] (applies, no path known) or \"N/A\" (doesn't apply)")
            for c in cats:
                need(f"risk.categories.{c}", c in RISK_CATEGORIES, "unknown category")
        need("risk.labels", is_str_list(risk.get("labels")) or risk.get("labels") == [],
             "list of tracker labels that force tier C (may be empty)")
        need("risk.exclude", "exclude" not in risk or is_str_list(risk.get("exclude")) or risk.get("exclude") == [],
             "optional list of globs excluded from every category (test files)")
        need("risk.personal_data_fields",
             is_str_list(risk.get("personal_data_fields")) or risk.get("personal_data_fields") == [],
             "list of field names (may be empty)")
        th = risk.get("thresholds")
        if isinstance(th, dict):
            for k in ("s_files", "s_acs", "s_lines", "m_files", "m_lines"):
                need(f"risk.thresholds.{k}", isinstance(th.get(k), int) and th[k] > 0, "positive int")
        else:
            errs.append("risk.thresholds: object required")
    elif risk is not None:
        errs.append("risk: object required")
    return errs


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[1], file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1]) as f:
            g = json.load(f)
    except (OSError, ValueError) as e:
        print(f"cannot read {sys.argv[1]}: {e}", file=sys.stderr)
        return 2
    if not isinstance(g, dict):
        print("top level must be an object", file=sys.stderr)
        return 1
    errs = check(g)
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
