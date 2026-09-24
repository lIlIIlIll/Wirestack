from __future__ import annotations

import copy
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from tools import check_network_capabilities as gate
from tools import evidence_digest as digest


class NetworkCapabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.description = json.loads((gate.ROOT / gate.DESCRIPTION).read_text())
        cls.inventory = gate.api.build_inventory(gate.ROOT, task_id=gate.TASK)

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="wirestack-capability-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.data = copy.deepcopy(self.description)
        paths = gate.native_inputs(gate.ROOT, self.data) | set(gate.DOCS) | {self.data["sdk_reference"]}
        for relative in paths:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(gate.ROOT / relative, target)
        # Validator fixtures are not execution evidence and never leave this temporary root.
        archive = self.root / "build/fixture.tar.gz"
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(b"unit fixture artifact\x00")
        log = self.root / "build/native.log"
        log.write_text("unit fixture output\n")
        source = digest.TextEvidenceDigest(gate.release.source_tree_sha256(self.root)).to_json()
        pin = json.loads((self.root / self.data["sdk_reference"]).read_text())["sdk"]
        observations = {name: {} for name in gate.SOCKETS}
        for row in self.data["rows"]:
            if row["capability_field"] is not None:
                observations[row["object"]][row["capability_field"]] = row["supported"]
        text = {"path": "build/native.log", "digest": digest.text_evidence_digest(log).to_json()}
        self.receipt = {
            "schema_version": 1, "source_task": gate.TASK, "status": "PASS",
            "platform": self.data["platform"], "native_execution": True, "cross_compiled": False,
            "source_digest": source, "installed_source_digest": source,
            "capability_description_digest": digest.text_evidence_digest(self.root / gate.DESCRIPTION).to_json(),
            "sdk": {"archive": {"domain": digest.ARTIFACT_BYTE_DOMAIN, "sha256": pin["sha256"]},
                    "matched_archive_files": 1},
            "scenarios": [{"id": name, "status": "PASS"} for name in self.data["required_scenarios"]],
            "observed_capabilities": observations,
            "artifact": {"path": "build/fixture.tar.gz", "digest": digest.artifact_byte_digest(archive).to_json()},
            "commands": [{"exit_code": 0, "timed_out": False, "stdout": text, "stderr": text}],
            "input_digests": {name: digest.text_evidence_digest(self.root / name).to_json()
                              for name in gate.native_inputs(self.root, self.data)},
        }
        self.receipt["capability_observations"] = {
            owner: [{"instance": "ipv4", "capabilities": dict(values)}]
            for owner, values in observations.items()
        }
        for row in self.data["rows"]:
            for instance, supported in row.get("instance_support", {}).items():
                values = dict(observations[row["object"]])
                values[row["capability_field"]] = supported
                self.receipt["capability_observations"][row["object"]].append(
                    {"instance": instance, "capabilities": values})

        gate.validate_description(self.root, self.data, self.inventory)
        gate.validate_native(self.root, self.data, self.receipt)

    def reject_receipt(self) -> None:
        with self.assertRaises(ValueError):
            gate.validate_native(self.root, self.data, self.receipt)

    def test_removed_public_operation_is_not_supported_by_a_type_name(self) -> None:
        inventory = copy.deepcopy(self.inventory)
        udp = next(item for item in inventory["declarations"]
                   if item["package"] == "wirestack.net" and item["name"] == "UdpSocket")
        udp["members"] = [member for member in udp["members"] if member["name"] != "send"]
        with self.assertRaises(ValueError):
            gate.validate_description(self.root, self.data, inventory)

    def test_new_public_operation_cannot_escape_the_mapping(self) -> None:
        inventory = copy.deepcopy(self.inventory)
        udp = next(item for item in inventory["declarations"]
                   if item["package"] == "wirestack.net" and item["name"] == "UdpSocket")
        udp["members"].append({"kind": "func", "name": "unmappedOperation", "signature": "public func unmappedOperation(): Unit"})
        with self.assertRaises(ValueError):
            gate.validate_description(self.root, self.data, inventory)

    def test_constructor_semantics_are_checked_not_just_member_presence(self) -> None:
        inventory = copy.deepcopy(self.inventory)
        constructor = gate.symbol_index(inventory)["wirestack.net.SocketCapabilities.init"]
        constructor["signature"] = constructor["signature"].replace("broadcast!: Bool = false", "broadcast!: Bool = true")
        with self.assertRaises(ValueError):
            gate.validate_description(self.root, self.data, inventory)

    def test_missing_field_conditions_backend_or_scenario_is_rejected(self) -> None:
        for field, replacement in (("conditions", []), ("backend_symbols", ["std.net.Nonexistent"]),
                                   ("scenario_ids", []), ("capability_field", "unknownField")):
            with self.subTest(field=field):
                data = copy.deepcopy(self.data)
                data["rows"][0][field] = replacement
                with self.assertRaises(ValueError):
                    gate.validate_description(self.root, data, self.inventory)

    def test_condition_deletion_changes_generated_correspondence(self) -> None:
        gate.documentation(self.root, self.data, write=False)
        row = next(row for row in self.data["rows"] if len(row["conditions"]) > 1)
        row["conditions"].pop(0)
        with self.assertRaises(ValueError):
            gate.documentation(self.root, self.data, write=False)

    def test_supported_claim_cannot_contradict_observed_socket(self) -> None:
        gate.validate_native(self.root, self.data, self.receipt)
        self.receipt["observed_capabilities"]["UdpSocket"]["broadcast"] = False
        self.reject_receipt()

    def test_missing_and_skipped_scenarios_do_not_inherit_top_level_pass(self) -> None:
        original = copy.deepcopy(self.receipt)
        self.receipt["scenarios"].pop()
        self.reject_receipt()
        self.receipt = original
        self.receipt["scenarios"][0]["status"] = "SKIPPED"
        self.reject_receipt()

    def test_cross_compilation_is_not_native_execution(self) -> None:
        self.receipt["cross_compiled"] = True
        self.reject_receipt()

    def test_permission_failure_cannot_be_counted_as_supported_execution(self) -> None:
        self.receipt["scenarios"][0]["status"] = "ENVIRONMENT_FAILURE"
        self.reject_receipt()

    def test_sdk_digest_uses_archive_bytes_not_the_text_domain(self) -> None:
        self.receipt["sdk"]["archive"]["domain"] = digest.TEXT_EVIDENCE_DOMAIN
        self.reject_receipt()

    def test_wrong_sdk_archive_is_rejected_even_with_a_matching_target(self) -> None:
        self.receipt["sdk"]["archive"]["sha256"] = "0" * 64
        self.reject_receipt()

    def test_changed_source_and_qualification_helper_invalidate_receipt(self) -> None:
        for name in ("src/net/udp_socket.cj", "tools/m8_002_native_sockets.py"):
            with self.subTest(input=name):
                path = self.root / name
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b"\n")
                    self.reject_receipt()
                finally:
                    path.write_bytes(original)

    def test_missing_execution_input_is_not_ignored(self) -> None:
        del self.receipt["input_digests"]["tools/m8_003_native_sockets.py"]
        self.reject_receipt()

    def test_description_drift_invalidates_runtime_correspondence(self) -> None:
        path = self.root / gate.DESCRIPTION
        path.write_text(path.read_text() + "\n")
        self.reject_receipt()

    def test_artifact_tamper_is_rejected(self) -> None:
        (self.root / "build/fixture.tar.gz").write_bytes(b"changed artifact")
        self.reject_receipt()

    def test_nested_scenario_log_tamper_is_rejected(self) -> None:
        path = self.root / "build/peer.log"
        path.write_text("original peer transcript\n")
        self.receipt["scenarios"][0]["details"] = {
            "syscalls": {"path": "build/peer.log", "digest": digest.text_evidence_digest(path).to_json()}}
        gate.validate_native(self.root, self.data, self.receipt)
        path.write_text("changed peer transcript\n")
        self.reject_receipt()

    def test_nonzero_or_timed_out_command_is_not_pass(self) -> None:
        for key, value in (("exit_code", 1), ("timed_out", True)):
            original = self.receipt["commands"][0][key]
            self.receipt["commands"][0][key] = value
            self.reject_receipt()
            self.receipt["commands"][0][key] = original

    def test_relative_evidence_cannot_escape_through_a_symlink(self) -> None:
        target = self.root / "build/outside.log"
        target.symlink_to(gate.ROOT / "LICENSE")
        self.receipt["commands"][0]["stdout"] = {
            "path": "build/outside.log", "digest": digest.text_evidence_digest(gate.ROOT / "LICENSE").to_json()}
        self.reject_receipt()

    def test_missing_ipv6_observation_cannot_hide_conditional_support(self) -> None:
        self.receipt["capability_observations"]["UdpSocket"] = [
            item for item in self.receipt["capability_observations"]["UdpSocket"] if item["instance"] != "ipv6"]
        self.reject_receipt()

    def test_ipv6_cannot_inherit_ipv4_broadcast_support(self) -> None:
        for item in self.receipt["capability_observations"]["UdpSocket"]:
            if item["instance"] == "ipv6":
                item["capabilities"]["broadcast"] = True
        self.reject_receipt()


if __name__ == "__main__":
    unittest.main()
