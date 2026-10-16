"""Keep resolved translator findings covered by adaptation provenance checks."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "javascript_compatibility", ROOT / "tools/javascript_compatibility.py"
)
compatibility = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(compatibility)


class RepositoryInventoryTests(unittest.TestCase):
    def test_checked_in_inventory_and_source_pins(self):
        manifest = json.loads((ROOT / "tests/javascript/corpus/manifest.json").read_text())
        compatibility.verify_pins(manifest)


class AdaptationInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.upstream = self.root / "upstream"
        self.upstream.mkdir()
        self.corpus = self.root / "corpus"
        (self.corpus / "test262").mkdir(parents=True)
        source = b"predicate channel"
        (self.upstream / "Grammar.g4").write_bytes(source)
        (self.root / "native.w").write_text("# native adaptation\n")
        (self.corpus / "test262/LICENSE").write_bytes(b"license")
        self.write_json("UPSTREAM.json", {
            "commit": "pinned",
            "files": [{"path": "Grammar.g4", "sha256": hashlib.sha256(source).hexdigest()}],
        })
        self.profile = {
            "upstream_commit": "pinned",
            "sites": [{"file": "Grammar.g4", "line": 1, "offset": 0,
                       "expected": "predicate", "status": "deferred", "native_files": []}],
            "resolved_sites": [{"file": "Grammar.g4", "line": 1, "offset": 10,
                                "expected": "channel", "status": "adapted-subset",
                                "native_files": ["native.w"],
                                "resolution": "Generic channel support is implemented."}],
        }
        (self.upstream / "BLOCKERS.txt").write_text("libs/Grammar.g4:1:1: predicate\n")
        self.manifest = {"cases": [], "real_sources": [],
                         "upstream": {"license_sha256": hashlib.sha256(b"license").hexdigest()}}
        self.paths = patch.multiple(compatibility, ROOT=self.root,
                                    UPSTREAM=self.upstream, CORPUS=self.corpus)
        self.paths.start()
        self.addCleanup(self.paths.stop)

    def write_json(self, name, data):
        (self.upstream / name).write_text(json.dumps(data))

    def verify(self):
        self.write_json("ADAPTATIONS.json", self.profile)
        return compatibility.verify_pins(self.manifest)

    def test_resolved_sites_are_verified_without_remaining_blockers(self):
        self.assertEqual(2, self.verify())

    def test_active_inventory_drift_still_fails(self):
        self.profile["sites"] = []
        with self.assertRaisesRegex(ValueError, "adaptation site inventory changed"):
            self.verify()

    def test_resolved_source_anchor_drift_fails(self):
        self.profile["resolved_sites"][0]["offset"] = 9
        with self.assertRaisesRegex(ValueError, "unknown or changed adaptation site"):
            self.verify()

    def test_resolved_native_reference_is_checked(self):
        (self.root / "native.w").unlink()
        with self.assertRaisesRegex(ValueError, "missing native adaptation"):
            self.verify()

    def test_resolution_is_required(self):
        del self.profile["resolved_sites"][0]["resolution"]
        with self.assertRaisesRegex(ValueError, "resolved adaptation lacks a resolution"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
