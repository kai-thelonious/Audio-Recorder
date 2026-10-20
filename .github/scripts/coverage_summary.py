#!/usr/bin/env python3
"""Turn `xcrun xccov view --report --json` output into a Markdown table.

Usage: coverage_summary.py coverage.json [target-name]

Writes to $GITHUB_STEP_SUMMARY when that is set (so it appears on the workflow
run page), and always prints to stdout. Only the app target is listed by
default; the test target's own coverage is not interesting.
"""
import json
import os
import sys


def main() -> int:
    report = json.load(open(sys.argv[1]))
    wanted = sys.argv[2] if len(sys.argv) > 2 else "AudioRecorder.app"
    targets = [t for t in report.get("targets", []) if t.get("name") == wanted]
    if not targets:
        names = ", ".join(t.get("name", "?") for t in report.get("targets", []))
        print(f"No coverage for target {wanted!r}. Targets in the report: {names}", file=sys.stderr)
        return 1
    target = targets[0]

    def pct(x: float) -> str:
        return f"{x * 100:.1f}%"

    lines = [
        f"### Code coverage: {pct(target['lineCoverage'])}",
        "",
        f"{target['coveredLines']} of {target['executableLines']} executable lines in `{wanted}` "
        "are covered by the tests.",
        "",
        "| File | Coverage | Lines |",
        "| --- | ---: | ---: |",
    ]
    for f in sorted(target.get("files", []), key=lambda f: (f["lineCoverage"], f["name"])):
        lines.append(f"| `{f['name']}` | {pct(f['lineCoverage'])} | {f['coveredLines']}/{f['executableLines']} |")
    text = "\n".join(lines) + "\n"

    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            out.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
