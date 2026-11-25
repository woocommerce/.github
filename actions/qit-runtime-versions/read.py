import json
from pathlib import Path
import re
import sys


CHECKS = {
    "activation": "Activation",
    "e2e": "Woo E2E",
    "woo-api": "Woo API",
    "woo-e2e": "Woo E2E",
    "woo-e2e-stable": "Woo E2E stable retry",
}
VERSION = re.compile(r"[0-9][0-9A-Za-z.+-]*")
VERSION_FIELDS = ("wordpress_version", "woocommerce_version", "php_version")


def resolved_versions(directory):
    environments = {}
    retry_record = directory / "woo-e2e-stable.runtime.json"
    has_retry = retry_record.is_file() and retry_record.stat().st_size > 0

    def add(record, key):
        versions = tuple(record.get(field) for field in VERSION_FIELDS)
        if all(isinstance(version, str) and VERSION.fullmatch(version) for version in versions):
            environments.setdefault(versions, set()).add(CHECKS[key])

    for path in sorted(directory.glob("*.json")):
        try:
            result = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(result, dict):
            continue
        if path.name.endswith((".runtime.json", ".record.json")):
            test = path.name.split(".", 1)[0]
            # A retry replaces the first Woo E2E result if its package could not cover the requested version.
            if test == "woo-e2e" and has_retry:
                continue
            if test in CHECKS:
                add(result, test)
            continue

        runs = result.get("test_runs")
        if not isinstance(runs, list):
            continue
        for run in runs:
            if not isinstance(run, dict):
                continue
            test = run.get("test_type")
            if isinstance(test, str) and test in CHECKS:
                add(run, test)

    return "; ".join(
        f"WordPress {wp} / WooCommerce {wc} / PHP {php} ({', '.join(sorted(checks))})"
        for (wp, wc, php), checks in environments.items()
    )


if __name__ == "__main__":
    print(resolved_versions(Path(sys.argv[1])))
