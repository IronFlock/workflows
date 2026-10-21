#!/usr/bin/env python3
"""Black-box tests for sarif-summary.py. Run: python3 -I scripts/test_sarif_summary.py"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sarif-summary.py")
TODAY = "2026-10-21"


def sarif(tool, rules, results):
    return {"version": "2.1.0", "runs": [{"tool": {"driver": {"name": tool, "rules": rules}}, "results": results}]}


def result(rule_id, level=None, uri="main.go", line=1, message="m"):
    r = {"ruleId": rule_id, "message": {"text": message}}
    if level:
        r["level"] = level
    if uri:
        r["locations"] = [{"physicalLocation": {"artifactLocation": {"uri": uri}, "region": {"startLine": line}}}]
    return r


class Case:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "findings")
        os.makedirs(self.dir)

    def add(self, name, doc):
        with open(os.path.join(self.dir, name), "w") as fh:
            json.dump(doc, fh)

    def file(self, name, text):
        path = os.path.join(self.tmp.name, name)
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def report(self, fail_on="", vex=None, trivyignore=None, jobs=None):
        out = os.path.join(self.tmp.name, "out")
        open(out, "w").close()
        cmd = [sys.executable, "-I", SCRIPT, "report", "--dir", self.dir, "--fail-on", fail_on, "--output", out]
        if vex:
            cmd += ["--vex", vex]
        if trivyignore:
            cmd += ["--trivyignore", trivyignore]
        if jobs is not None:
            cmd += ["--jobs", json.dumps(jobs)]
        proc = subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, "SUMMARY_TODAY": TODAY})
        with open(out) as fh:
            outputs = dict(line.split("=", 1) for line in fh.read().splitlines())
        findings = json.loads(outputs["findings"]) if "findings" in outputs else {}
        return proc, findings


class Base(unittest.TestCase):
    def case(self):
        c = Case()
        self.addCleanup(c.tmp.cleanup)
        return c


class ReportTests(Base):
    def test_gitleaks_is_secret_and_blocks_only_when_listed(self):
        c = self.case()
        c.add("gitleaks.sarif", sarif("gitleaks", [{"id": "generic-api-key"}], [result("generic-api-key", uri="a.env")]))
        proc, findings = c.report()
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertEqual(findings["secrets"], 1)
        proc, _ = c.report("secrets")
        self.assertEqual(proc.returncode, 1)

    def test_trivy_severity_and_vuln_high_covers_critical(self):
        c = self.case()
        rules = [
            {"id": "CVE-2024-0001", "properties": {"tags": ["vulnerability", "security", "CRITICAL"], "security-severity": "9.8"}},
            {"id": "CVE-2024-0002", "properties": {"tags": ["vulnerability", "security", "MEDIUM"], "security-severity": "5.5"}},
            {"id": "DS-0002", "properties": {"tags": ["misconfiguration", "security", "HIGH"], "security-severity": "8.0"}},
            {"id": "aws-access-key-id", "properties": {"tags": ["secret", "security", "CRITICAL"], "security-severity": "9.5"}},
        ]
        c.add("trivy.sarif", sarif("Trivy", rules, [result(r["id"], "error") for r in rules]))
        proc, findings = c.report("vuln-high")
        self.assertEqual(findings["vuln-critical"], 1)
        self.assertEqual(findings["vuln-other"], 1)
        self.assertEqual(findings["misconfig-high"], 1)
        self.assertEqual(findings["secrets"], 1)
        self.assertEqual(proc.returncode, 1, "vuln-high must also block critical findings")
        proc, _ = c.report("misconfig-high")
        self.assertEqual(proc.returncode, 1)

    def test_govulncheck_only_reachable_is_high(self):
        c = self.case()
        c.add("gv.sarif", sarif("govulncheck", [{"id": "GO-2021-0113"}, {"id": "GO-2022-1059"}],
                                [result("GO-2021-0113", "error"), result("GO-2022-1059", "warning")]))
        proc, findings = c.report("vuln-high")
        self.assertEqual((findings["vuln-high"], findings["vuln-other"]), (1, 1))
        self.assertEqual(proc.returncode, 1)

    def test_vex_suppresses_until_twelve_months(self):
        c = self.case()
        c.add("gv.sarif", sarif("govulncheck", [{"id": "GO-2021-0113"}], [result("GO-2021-0113", "error")]))
        fresh = c.file("fresh.json", json.dumps({"timestamp": "2026-06-01T00:00:00Z", "statements": [
            {"vulnerability": {"name": "GO-2021-0113"}, "status": "not_affected",
             "justification": "vulnerable_code_not_in_execute_path", "timestamp": "2026-06-01T00:00:00Z"}]}))
        proc, findings = c.report("vuln-high", vex=fresh)
        self.assertEqual(findings["vuln-high"], 0)
        self.assertEqual(proc.returncode, 0, proc.stdout)
        self.assertIn("Accepted by VEX", proc.stdout)
        stale = c.file("stale.json", json.dumps({"statements": [
            {"vulnerability": {"name": "GO-2021-0113"}, "status": "not_affected",
             "justification": "vulnerable_code_not_in_execute_path", "timestamp": "2025-09-01T00:00:00Z"}]}))
        proc, findings = c.report("vuln-high", vex=stale)
        self.assertEqual(findings["vuln-high"], 1)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("VEX `GO-2021-0113` expired 2026-09-01", proc.stdout)

    def test_osv_without_score_uses_level(self):
        c = self.case()
        c.add("osv.sarif", sarif("osv-scanner", [{"id": "GHSA-1"}, {"id": "GHSA-2"}],
                                 [result("GHSA-1", "error"), result("GHSA-2", "warning")]))
        _, findings = c.report()
        self.assertEqual((findings["vuln-high"], findings["vuln-other"]), (1, 1))

    def test_vex_without_justification_is_ignored(self):
        c = self.case()
        c.add("gv.sarif", sarif("govulncheck", [{"id": "GO-2021-0113"}], [result("GO-2021-0113", "error")]))
        vex = c.file("v.json", json.dumps({"statements": [
            {"vulnerability": {"name": "GO-2021-0113"}, "status": "not_affected", "timestamp": "2026-10-01T00:00:00Z"}]}))
        proc, findings = c.report("vuln-high", vex=vex)
        self.assertEqual(findings["vuln-high"], 1)
        self.assertIn("no justification", proc.stdout)

    def test_semgrep_level_from_rule_default(self):
        c = self.case()
        c.add("s.sarif", sarif("Semgrep OSS", [{"id": "r1", "defaultConfiguration": {"level": "error"}},
                                               {"id": "r2", "defaultConfiguration": {"level": "warning"}}],
                               [result("r1"), result("r2")]))
        proc, findings = c.report("semgrep-error")
        self.assertEqual((findings["semgrep-error"], findings["semgrep-other"]), (1, 1))
        self.assertEqual(proc.returncode, 1)

    def test_licenses(self):
        c = self.case()
        c.add("licenses.json", {"Results": [{"Target": "go.mod", "Licenses": [
            {"Name": "AGPL-3.0", "Category": "forbidden", "PkgName": "x"},
            {"Name": "AGPL-3.0", "Category": "forbidden", "PkgName": "x"},
            {"Name": "LGPL-2.1", "Category": "restricted", "PkgName": "y"},
            {"Name": "MIT", "Category": "notice", "PkgName": "z"}]}]})
        proc, findings = c.report("license-forbidden")
        self.assertEqual((findings["license-forbidden"], findings["license-restricted"]), (1, 1))
        self.assertEqual(proc.returncode, 1)

    def test_failed_scanner_job_fails_even_report_only(self):
        c = self.case()
        proc, _ = c.report("", jobs={"deps": {"result": "failure"}, "image": {"result": "skipped"}})
        self.assertEqual(proc.returncode, 1)
        self.assertIn("deps", proc.stdout)

    def test_unknown_category_is_rejected(self):
        proc, _ = self.case().report("vuln-medium")
        self.assertEqual(proc.returncode, 2)

    def test_trivyignore_expiry_listed(self):
        c = self.case()
        ti = c.file(".trivyignore.yaml", "vulnerabilities:\n  - id: CVE-1\n    statement: x\n    expired_at: 2026-11-01\n"
                                         "  - id: CVE-2\n    statement: y\nmisconfigurations:\n  - id: DS-0026\n    expired_at: 2027-06-01\n")
        proc, _ = c.report("", trivyignore=ti)
        self.assertIn("`CVE-1` expires 2026-11-01", proc.stdout)
        self.assertIn("`CVE-2` has no expired_at", proc.stdout)
        self.assertNotIn("DS-0026", proc.stdout)


class UploadCopyTests(Base):
    def test_drops_locationless_and_duplicate_runs(self):
        c = self.case()
        c.add("govulncheck-code.sarif", sarif("govulncheck", [{"id": "GO-1"}], [result("GO-1", "error")]))
        c.add("govulncheck-frpc.sarif", sarif("govulncheck", [{"id": "GO-2"}], [result("GO-2", "error", uri=None)]))
        c.add("osv.sarif", sarif("osv-scanner", [{"id": "GHSA-1"}], [result("GHSA-1", "error", uri=None)]))
        c.add("trivy.sarif", sarif("Trivy", [], []))
        out = os.path.join(c.tmp.name, "cs")
        subprocess.run([sys.executable, "-I", SCRIPT, "upload-copy", "--dir", c.dir, "--out", out], check=True, capture_output=True)
        self.assertEqual(sorted(os.listdir(out)), ["govulncheck-code.sarif", "trivy.sarif"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
