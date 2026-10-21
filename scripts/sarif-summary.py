#!/usr/bin/env python3
"""Summarise scanner findings and decide whether they block.

  sarif-summary.py report --dir DIR [--fail-on CATS] [--vex FILE] [--trivyignore FILE]
                          [--jobs JSON] [--summary FILE] [--output FILE]
  sarif-summary.py upload-copy --dir DIR --out DIR

`report` reads every *.sarif and licenses*.json below DIR, sorts each finding
into one category, drops findings an OpenVEX statement marks not_affected or
fixed, prints a Markdown summary (also appended to --summary) and writes
`findings` (JSON counts) and `blocking` (count) to --output. It exits 1 when a
category listed in --fail-on has findings, or when a scanner job failed.

Categories: secrets, vuln-critical, vuln-high, vuln-other, misconfig-high,
misconfig-other, license-forbidden, license-restricted, semgrep-error,
semgrep-other, other. `vuln-high` in --fail-on blocks high and critical.

`upload-copy` writes SARIF copies for GitHub code scanning: results without a
source location are dropped (code scanning rejects them), and only the first
run per tool is kept.

Standard library only; run with `python3 -I`.
"""

import argparse
import datetime as dt
import glob
import json
import os
import re
import sys

FAIL_CATEGORIES = {"secrets", "vuln-critical", "vuln-high", "misconfig-high",
                   "license-forbidden", "semgrep-error"}
ORDER = ["secrets", "vuln-critical", "vuln-high", "vuln-other", "misconfig-high",
         "misconfig-other", "license-forbidden", "license-restricted",
         "semgrep-error", "semgrep-other", "other"]
ID_RE = re.compile(r"\b(CVE-\d{4}-\d{4,}|GHSA(?:-[23456789cfghjmpqrvwx]{4}){3}|GO-\d{4}-\d{4,}|PYSEC-\d{4}-\d+)\b")
VEX_MAX_AGE = dt.timedelta(days=365)
EXPIRY_WARN = dt.timedelta(days=30)


def today():
    override = os.environ.get("SUMMARY_TODAY")
    return dt.date.fromisoformat(override) if override else dt.date.today()


def parse_date(text):
    if not text:
        return None
    try:
        return dt.date.fromisoformat(str(text).strip().strip("'\"")[:10])
    except ValueError:
        return None


def severity_score(rule, result):
    for props in (result.get("properties") or {}, rule.get("properties") or {}):
        value = props.get("security-severity")
        if value is not None:
            try:
                return float(value)
            except (TypeError, ValueError):
                pass
    tags = [str(t).upper() for t in (rule.get("properties") or {}).get("tags", [])]
    for name, score in (("CRITICAL", 9.5), ("HIGH", 8.0), ("MEDIUM", 5.5), ("LOW", 2.0)):
        if name in tags:
            return score
    return None


def level_of(rule, result):
    return result.get("level") or (rule.get("defaultConfiguration") or {}).get("level") or "warning"


def vuln_category(score, level):
    if score is None:
        return "vuln-high" if level == "error" else "vuln-other"
    if score >= 9.0:
        return "vuln-critical"
    if score >= 7.0:
        return "vuln-high"
    return "vuln-other"


def classify(tool, rule, result):
    tool = tool.lower()
    tags = {str(t).lower() for t in (rule.get("properties") or {}).get("tags", [])}
    score = severity_score(rule, result)
    level = level_of(rule, result)
    if "gitleaks" in tool:
        return "secrets"
    if "trivy" in tool:
        if "secret" in tags:
            return "secrets"
        if "misconfiguration" in tags:
            return "misconfig-high" if score is not None and score >= 7.0 else "misconfig-other"
        return vuln_category(score, level)
    if "govulncheck" in tool:
        # govulncheck: error = vulnerable symbol is called, warning = package
        # imported, note = module required. Only reachable code counts as high.
        return "vuln-high" if level == "error" else "vuln-other"
    if "osv" in tool:
        return vuln_category(score, level)
    if "semgrep" in tool:
        return "semgrep-error" if level == "error" else "semgrep-other"
    return "other"


def rule_index(run):
    driver = (run.get("tool") or {}).get("driver") or {}
    rules = driver.get("rules") or []
    return driver.get("name") or "unknown", {r.get("id"): r for r in rules}, rules


def finding_ids(rule, result):
    ids = {result.get("ruleId") or ""}
    texts = [rule.get("name"), (rule.get("shortDescription") or {}).get("text"),
             (rule.get("fullDescription") or {}).get("text"), (rule.get("help") or {}).get("text"),
             (result.get("message") or {}).get("text")]
    for text in texts:
        if text:
            ids.update(ID_RE.findall(text))
    ids.discard("")
    return ids


def location_of(result):
    for loc in result.get("locations") or []:
        phys = loc.get("physicalLocation") or {}
        uri = (phys.get("artifactLocation") or {}).get("uri")
        if uri:
            line = (phys.get("region") or {}).get("startLine")
            return f"{uri}:{line}" if line else uri
    return ""


def load_vex(path):
    """Return ({vuln id: (status, justification, valid_until)}, warnings)."""
    entries, warnings = {}, []
    if not path or not os.path.isfile(path):
        return entries, warnings
    with open(path, encoding="utf-8") as fh:
        doc = json.load(fh)
    doc_ts = parse_date(doc.get("timestamp"))
    for st in doc.get("statements") or []:
        status = st.get("status")
        if status not in ("not_affected", "fixed"):
            continue
        ts = parse_date(st.get("timestamp")) or doc_ts
        valid_until = ts + VEX_MAX_AGE if ts else None
        vuln = st.get("vulnerability") or {}
        names = [vuln.get("name") or vuln.get("@id")] + list(vuln.get("aliases") or [])
        justification = st.get("justification") or st.get("impact_statement") or ""
        if status == "not_affected" and not justification:
            warnings.append(f"VEX statement for {names[0]} has no justification; ignored")
            continue
        if valid_until is None:
            warnings.append(f"VEX statement for {names[0]} has no timestamp; ignored")
            continue
        for name in filter(None, names):
            entries[name] = (status, justification, valid_until)
    return entries, warnings


def load_trivyignore_expiry(path):
    """Minimal reader for .trivyignore.yaml: [(id, expired_at or None)]."""
    out = []
    if not path or not os.path.isfile(path):
        return out
    current = None
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].rstrip()
            m = re.match(r"^\s*-\s*id:\s*(\S+)", line)
            if m:
                if current:
                    out.append(tuple(current))
                current = [m.group(1).strip("'\""), None]
                continue
            m = re.match(r"^\s*expired_at:\s*(\S+)", line)
            if m and current:
                current[1] = parse_date(m.group(1))
    if current:
        out.append(tuple(current))
    return out


def collect(directory, vex):
    findings, suppressed, scanned = [], [], []
    now = today()
    for path in sorted(glob.glob(os.path.join(directory, "**", "*.sarif"), recursive=True)):
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        scanned.append(os.path.relpath(path, directory))
        for run in doc.get("runs") or []:
            tool, rules, rule_list = rule_index(run)
            for result in run.get("results") or []:
                rule = rules.get(result.get("ruleId"))
                if rule is None and isinstance(result.get("ruleIndex"), int) and result["ruleIndex"] < len(rule_list):
                    rule = rule_list[result["ruleIndex"]]
                rule = rule or {}
                category = classify(tool, rule, result)
                item = {
                    "tool": tool,
                    "category": category,
                    "rule": result.get("ruleId") or rule.get("id") or "?",
                    "location": location_of(result),
                    "message": " ".join(((result.get("message") or {}).get("text") or "").split())[:140],
                }
                match = None
                if category.startswith("vuln"):
                    for vid in finding_ids(rule, result):
                        if vid in vex:
                            match = (vid, vex[vid])
                            break
                if match and match[1][2] >= now:
                    item["vex"] = f"{match[0]}: {match[1][0]} ({match[1][1]})"
                    suppressed.append(item)
                else:
                    if match:
                        item["message"] = f"[VEX statement expired {match[1][2]}] " + item["message"]
                    findings.append(item)
    for path in sorted(glob.glob(os.path.join(directory, "**", "licenses*.json"), recursive=True)):
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        scanned.append(os.path.relpath(path, directory))
        seen = set()
        for res in doc.get("Results") or []:
            for lic in res.get("Licenses") or []:
                cat = (lic.get("Category") or "").lower()
                if cat not in ("forbidden", "restricted"):
                    continue
                key = (lic.get("PkgName") or lic.get("FilePath") or "", lic.get("Name") or "")
                if key in seen:
                    continue
                seen.add(key)
                findings.append({
                    "tool": "trivy-license",
                    "category": f"license-{cat}",
                    "rule": lic.get("Name") or "?",
                    "location": key[0],
                    "message": f"{lic.get('Name')} ({cat}) in {key[0] or res.get('Target')}",
                })
    return findings, suppressed, scanned


def cmd_report(args):
    fail_on = {c.strip() for c in (args.fail_on or "").split(",") if c.strip()}
    unknown = fail_on - FAIL_CATEGORIES
    if unknown:
        print(f"unknown --fail-on categories: {', '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    vex, warnings = load_vex(args.vex)
    findings, suppressed, scanned = collect(args.dir, vex)
    now = today()

    counts = {c: 0 for c in ORDER}
    for f in findings:
        counts[f["category"]] = counts.get(f["category"], 0) + 1
    blocking_cats = set(fail_on)
    if "vuln-high" in fail_on:
        blocking_cats.add("vuln-critical")
    blocking = sum(counts[c] for c in blocking_cats)

    # A cancelled job (e.g. a timeout) left the scan incomplete, just like a failed one.
    failed_jobs = []
    if args.jobs:
        for name, job in json.loads(args.jobs).items():
            if (job or {}).get("result") in ("failure", "cancelled"):
                failed_jobs.append(name)

    expiring = []
    for vid, (status, _, until) in sorted(vex.items()):
        if until < now:
            expiring.append(f"VEX `{vid}` expired {until} (statements are valid 12 months)")
        elif until - now <= EXPIRY_WARN:
            expiring.append(f"VEX `{vid}` expires {until}")
    for vid, exp in load_trivyignore_expiry(args.trivyignore):
        if exp is None:
            expiring.append(f".trivyignore `{vid}` has no expired_at")
        elif exp < now:
            expiring.append(f".trivyignore `{vid}` expired {exp}")
        elif exp - now <= EXPIRY_WARN:
            expiring.append(f".trivyignore `{vid}` expires {exp}")

    mode = f"fail on: `{','.join(sorted(fail_on))}`" if fail_on else "report-only"
    lines = ["## Security scan", "", f"Mode: {mode}. Scanned: {len(scanned)} report(s).", "",
             "| Category | Findings | Blocks |", "|---|---:|---|"]
    for c in ORDER:
        if counts[c] or c in FAIL_CATEGORIES:
            lines.append(f"| {c} | {counts[c]} | {'yes' if c in blocking_cats and counts[c] else ''} |")
    if failed_jobs:
        lines += ["", f"**Scanner job(s) failed or were cancelled:** {', '.join(sorted(failed_jobs))} — the scan is incomplete."]
    if findings:
        lines += ["", "### Findings (first 50)", "", "| Category | Tool | Rule | Location | Message |", "|---|---|---|---|---|"]
        for f in sorted(findings, key=lambda x: (ORDER.index(x["category"]), x["tool"], x["rule"]))[:50]:
            msg = f["message"].replace("|", "\\|")
            lines.append(f"| {f['category']} | {f['tool']} | `{f['rule']}` | {f['location']} | {msg} |")
    if suppressed:
        lines += ["", "### Accepted by VEX", ""]
        lines += [f"- `{s['rule']}` {s['location']} — {s['vex']}" for s in suppressed[:50]]
    if expiring or warnings:
        lines += ["", "### Exceptions to review", ""] + [f"- {e}" for e in expiring + warnings]
    text = "\n".join(lines) + "\n"
    print(text)
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as fh:
            fh.write(text)
    if args.output:
        with open(args.output, "a", encoding="utf-8") as fh:
            fh.write(f"findings={json.dumps(counts, separators=(',', ':'))}\n")
            fh.write(f"blocking={blocking}\n")
    if failed_jobs:
        print(f"::error::scanner job(s) failed or were cancelled: {', '.join(sorted(failed_jobs))}")
        return 1
    if blocking:
        print(f"::error::{blocking} blocking finding(s) in: {', '.join(sorted(c for c in blocking_cats if counts[c]))}")
        return 1
    return 0


def cmd_upload_copy(args):
    os.makedirs(args.out, exist_ok=True)
    seen_tools = set()
    for path in sorted(glob.glob(os.path.join(args.dir, "**", "*.sarif"), recursive=True)):
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
        runs = []
        for run in doc.get("runs") or []:
            tool = ((run.get("tool") or {}).get("driver") or {}).get("name") or "unknown"
            results = run.get("results") or []
            located = [r for r in results if location_of(r)]
            if results and not located:
                continue
            if tool in seen_tools:
                continue
            seen_tools.add(tool)
            run["results"] = located
            runs.append(run)
        if runs:
            doc["runs"] = runs
            name = os.path.basename(path)
            with open(os.path.join(args.out, name), "w", encoding="utf-8") as fh:
                json.dump(doc, fh)
            print(f"upload copy: {name} ({sum(len(r['results']) for r in runs)} located results)")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    rep = sub.add_parser("report")
    rep.add_argument("--dir", required=True)
    rep.add_argument("--fail-on", default="")
    rep.add_argument("--vex")
    rep.add_argument("--trivyignore")
    rep.add_argument("--jobs", help="JSON of the needs context")
    rep.add_argument("--summary")
    rep.add_argument("--output")
    up = sub.add_parser("upload-copy")
    up.add_argument("--dir", required=True)
    up.add_argument("--out", required=True)
    args = parser.parse_args()
    return cmd_report(args) if args.cmd == "report" else cmd_upload_copy(args)


if __name__ == "__main__":
    sys.exit(main())
