#!/usr/bin/env python3
"""Reject a successful SwiftPM exit that did not actually run both XCTest targets."""
import json
from pathlib import Path
import re
import sys


def read_result(path):
    log = Path(path).read_text()
    counts = {
        target: len(re.findall(r"Test Case[^\n]*AgentPet" + target + r"Tests\.[^\n]*started\.", log))
        for target in ("Core", "App")
    }
    summary = re.search(
        r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests, with "
        r"(?:(\d+) tests? skipped and )?0 failures \(0 unexpected\)",
        log,
    )
    if not summary or not all(counts.values()) or sum(counts.values()) != int(summary[1]):
        raise ValueError("full requires a passing, nonempty XCTest run of both Core and App")
    return {"total": int(summary[1]), "core": counts["Core"], "app": counts["App"],
            "skipped": int(summary[2] or 0)}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: xctest_result.py LOG RESULT_JSON")
    try:
        result = read_result(sys.argv[1])
        Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + "\n")
    except (OSError, ValueError) as error:
        sys.exit("FAIL: " + str(error))
    print(f"PASS: {result['total']} XCTest tests (Core {result['core']}, App {result['app']})")
