import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "actions/qit-runtime-versions/read.py"
CAPTURE = SCRIPT.parent.parent / "capture-qit-runtime/capture.sh"


class RuntimeVersionsTest(unittest.TestCase):
    def test_action_groups_core_checks_and_excludes_default_scan_versions(self):
        stack = {"wordpress_version": "7.2-RC3", "woocommerce_version": "11.3.1", "php_version": "8.4"}
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "qit-result.json").write_text(json.dumps({"test_runs": [
                {"test_type": "activation", **stack},
                {"test_type": "woo-api", **stack},
                {"test_type": "e2e", **stack, "woocommerce_version": "11.4.0-rc.1"},
                {"test_type": "security", **stack, "wordpress_version": "7.1.5"},
                {"test_type": "activation", **stack, "wordpress_version": "rc"},
            ]}))
            self.assertEqual(
                self.read_versions(directory),
                "WordPress 7.2-RC3 / WooCommerce 11.3.1 / PHP 8.4 (Activation, Woo API); "
                "WordPress 7.2-RC3 / WooCommerce 11.4.0-rc.1 / PHP 8.4 (Woo E2E)",
            )

    def test_cli_uses_runtime_records_and_reports_a_stable_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stack = {"wordpress_version": "7.2-RC3", "woocommerce_version": "11.4.0-rc.1", "php_version": "8.4.28"}
            (root / "qit-woo-api-results.txt").write_text("WooCommerce 11.4.0-rc.1 has no released line of its own.\n")
            (root / "woo-api.runtime.json").write_text(json.dumps(stack))
            (root / "woo-e2e.runtime.json").write_text(json.dumps(stack))
            (root / "woo-e2e-stable.runtime.json").write_text(json.dumps({**stack, "woocommerce_version": "11.3.1"}))
            self.assertEqual(
                self.read_versions(directory),
                "WordPress 7.2-RC3 / WooCommerce 11.4.0-rc.1 / PHP 8.4.28 (Woo API); "
                "WordPress 7.2-RC3 / WooCommerce 11.3.1 / PHP 8.4.28 (Woo E2E stable retry)",
            )

    def test_missing_and_unreadable_results_produce_no_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "empty.record.json").touch()
            Path(directory, "qit-activation-results.txt").write_text("  Stack:       WordPress 7.2-RC3, PHP 8.4\n")
            self.assertEqual(self.read_versions(directory), "")

    def test_capture_records_installed_versions_and_always_stops_the_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            qit = root / "vendor/bin/qit"
            qit.parent.mkdir(parents=True)
            qit.write_text(
                "#!/usr/bin/env bash\n"
                "case \"$1\" in\n"
                "  env:exec)\n"
                "    [[ $2 == --env_id=qitenv123 && $* == *woocommerce.php* ]] || exit 2\n"
                "    [[ \"${FAIL_CAPTURE:-}\" != 1 ]] || exit 1\n"
                "    echo 'QIT_RUNTIME {\"wordpress_version\":\"7.2-RC3\","
                "\"woocommerce_version\":\"11.4.0-rc.1\",\"php_version\":\"8.4.28\"}' ;;\n"
                "  env:down) echo \"$2\" >> \"$GITHUB_WORKSPACE/stopped\" ;;\n"
                "  *) exit 2 ;;\n"
                "esac\n"
            )
            qit.chmod(0o755)
            results = root / "qit-results"
            results.mkdir()
            for check in ("activation", "woo-api"):
                (results / f"qit-{check}-results.txt").write_text("✅ Environment ready: qitenv123\n")
            env = {**os.environ, "GITHUB_WORKSPACE": directory}
            subprocess.run(["bash", CAPTURE, "activation"], env=env, check=True)
            failed = subprocess.run(["bash", CAPTURE, "woo-api"], env={**env, "FAIL_CAPTURE": "1"})
            self.assertEqual(failed.returncode, 1)
            self.assertEqual((root / "stopped").read_text(), "qitenv123\nqitenv123\n")
            self.assertEqual(
                self.read_versions(results),
                "WordPress 7.2-RC3 / WooCommerce 11.4.0-rc.1 / PHP 8.4.28 (Activation)",
            )

    def read_versions(self, directory):
        return subprocess.check_output([sys.executable, SCRIPT, directory], text=True).strip()


if __name__ == "__main__":
    unittest.main()
