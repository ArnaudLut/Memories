"""Tests du garde-fou des plans.

Les fichiers de fixtures/ sont de vrais plans, produits hors ligne par OpenTofu
1.13.9 et le fournisseur ovh 2.24.0 puis réduits aux champs que lit le
garde-fou. Les cas qu'un plan réel ne permet pas d'obtenir facilement sont
écrits à la main dans ce fichier.

Lancement : python3 -m unittest discover -s infra/policy/tests
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check_plan.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"

BUCKET = "ovh_cloud_storage_object_bucket.state"
DATABASE_SERVICE = "module.database.ovh_cloud_project_database.this"
DATABASE = "module.database.ovh_cloud_project_database_database.this"
INSTANCE = "module.instance.ovh_cloud_instance.this"
DNS_RECORD = "module.dns.ovh_domain_zone_record.this"
PROJECT = "ovh_cloud_project.this"


def run_guard(*arguments):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *(str(argument) for argument in arguments)],
        capture_output=True,
        text=True,
        check=False,
    )


def run_guard_on(document):
    """Lance le garde-fou sur un document écrit dans un fichier temporaire."""
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "plan.json"
        text = document if isinstance(document, str) else json.dumps(document)
        path.write_text(text, encoding="utf-8")
        return run_guard(path)


def change(address, resource_type, actions, mode="managed", **details):
    return {
        "address": address,
        "mode": mode,
        "type": resource_type,
        "name": address.rsplit(".", 1)[-1],
        "change": {"actions": actions, **details},
    }


def refused_addresses(result):
    return [line[2:].split(" ", 1)[0] for line in result.stdout.splitlines() if line.startswith("- ")]


class AcceptedPlans(unittest.TestCase):
    def test_plans_that_destroy_nothing_protected(self):
        for name in ("create", "no_changes", "update_in_place", "reinstall_instance"):
            with self.subTest(plan=name):
                result = run_guard(FIXTURES / f"{name}.json")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("Plan accepté", result.stdout)
                self.assertEqual(refused_addresses(result), [])

    def test_deleting_an_unprotected_resource_is_accepted(self):
        result = run_guard(FIXTURES / "delete_dns_record.json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(DNS_RECORD, result.stdout)

    def test_forgetting_a_protected_resource_is_accepted(self):
        result = run_guard(FIXTURES / "forget_bucket.json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_reading_a_data_source_of_a_protected_type_is_accepted(self):
        plan = {"resource_changes": [change("data.ovh_cloud_project.this", "ovh_cloud_project", ["read"], mode="data")]}
        result = run_guard_on(plan)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class RefusedPlans(unittest.TestCase):
    def assert_refused(self, name, expected_addresses, operation):
        result = run_guard(FIXTURES / f"{name}.json")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Plan refusé", result.stdout)
        self.assertEqual(refused_addresses(result), expected_addresses)
        for line in result.stdout.splitlines():
            if line.startswith("- "):
                self.assertTrue(line.endswith(f": {operation}"), line)

    def test_replacing_the_database_service(self):
        self.assert_refused("replace_database", [DATABASE_SERVICE, DATABASE], "remplacement")

    def test_replacing_the_database(self):
        self.assert_refused("replace_logical_database", [DATABASE], "remplacement")

    def test_replacing_the_state_bucket(self):
        self.assert_refused("replace_bucket", [BUCKET], "remplacement")

    def test_replacing_the_state_bucket_with_create_before_destroy(self):
        self.assert_refused("replace_bucket_create_first", [BUCKET], "remplacement")

    def test_deleting_the_state_bucket(self):
        self.assert_refused("delete_bucket", [BUCKET], "suppression")

    def test_deleting_the_project(self):
        self.assert_refused("delete_project", [PROJECT], "suppression")

    def test_destroy_plan_lists_every_protected_resource_and_nothing_else(self):
        self.assert_refused("destroy_everything", [BUCKET, DATABASE_SERVICE, DATABASE], "suppression")

    def test_deleting_a_deposed_object(self):
        deposed = change(DATABASE_SERVICE, "ovh_cloud_project_database", ["delete"])
        deposed["deposed"] = "00000000"
        result = run_guard_on({"resource_changes": [deposed]})
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(refused_addresses(result), [DATABASE_SERVICE])


class ReinstallNotice(unittest.TestCase):
    def notice_for(self, **details):
        plan = {"resource_changes": [change(INSTANCE, "ovh_cloud_instance", ["update"], **details)]}
        result = run_guard_on(plan)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return "sera réinstallée" in result.stdout

    def test_changed_user_data_is_announced_without_its_value(self):
        result = run_guard(FIXTURES / "reinstall_instance.json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"Attention : {INSTANCE} sera réinstallée", result.stdout)
        plan = json.loads((FIXTURES / "reinstall_instance.json").read_text(encoding="utf-8"))
        for entry in plan["resource_changes"]:
            if entry["type"] == "ovh_cloud_instance":
                for value in (entry["change"]["before"]["user_data"], entry["change"]["after"]["user_data"]):
                    self.assertNotIn(value, result.stdout + result.stderr)

    def test_other_plans_announce_nothing(self):
        for name in ("create", "no_changes", "update_in_place", "destroy_everything"):
            with self.subTest(plan=name):
                self.assertNotIn("réinstallée", run_guard(FIXTURES / f"{name}.json").stdout)

    def test_user_data_known_after_apply_is_announced(self):
        self.assertTrue(self.notice_for(before={"user_data": "YQ=="}, after={}, after_unknown={"user_data": True}))

    def test_emptied_user_data_is_announced(self):
        self.assertTrue(self.notice_for(before={"user_data": "YQ=="}, after={"user_data": ""}, after_unknown={}))

    def test_removed_user_data_is_not_announced(self):
        self.assertFalse(self.notice_for(before={"user_data": "YQ=="}, after={"user_data": None}, after_unknown={}))

    def test_unchanged_user_data_is_not_announced(self):
        self.assertFalse(self.notice_for(before={"user_data": "YQ=="}, after={"user_data": "YQ=="}, after_unknown={}))


class UnusableInput(unittest.TestCase):
    def assert_unusable(self, result):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotEqual(result.stderr, "")

    def test_missing_argument(self):
        self.assert_unusable(run_guard())

    def test_too_many_arguments(self):
        self.assert_unusable(run_guard(FIXTURES / "create.json", FIXTURES / "create.json"))

    def test_missing_file(self):
        self.assert_unusable(run_guard(FIXTURES / "absent.json"))

    def test_invalid_json(self):
        self.assert_unusable(run_guard_on("{"))

    def test_json_that_is_not_an_object(self):
        self.assert_unusable(run_guard_on([]))

    def test_state_instead_of_plan(self):
        self.assert_unusable(run_guard_on({"format_version": "1.0", "values": {"root_module": {}}}))

    def test_resource_changes_that_is_not_a_list(self):
        self.assert_unusable(run_guard_on({"resource_changes": {}}))

    def test_incomplete_entry(self):
        self.assert_unusable(run_guard_on({"resource_changes": [{"address": BUCKET, "mode": "managed", "type": "ovh_cloud_storage_object_bucket"}]}))


if __name__ == "__main__":
    unittest.main()
