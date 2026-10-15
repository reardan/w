"""Exercise Termux bootstrap selection without an Android device or network."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AndroidBootstrap(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile("wbuild", self.root / "wbuild")
        (self.root / "SEEDS").write_text("# No Android seed is published yet\n")
        (self.root / "bin").mkdir()
        (self.root / "commands").mkdir()
        self.script("commands/uname", "echo aarch64\n")
        self.env = dict(os.environ, ANDROID_ROOT="/system", WBUILDD="1")
        self.env["PATH"] = str(self.root / "commands") + ":" + os.environ["PATH"]

    def script(self, path, body):
        file = self.root / path
        file.write_text("#!/bin/sh\n" + body)
        file.chmod(0o755)

    def run_build(self, *args):
        return subprocess.run(["sh", "./wbuild", *args], cwd=self.root,
                              env=self.env, text=True, capture_output=True)

    def test_missing_seed_has_cross_build_instructions(self):
        result = self.run_build("verify")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bin/wv2 arm64_android w.w -o w_android", result.stderr)
        self.assertIn("Termux's private home", result.stderr)
        self.assertFalse((self.root / "w.download").exists())

    def test_rejects_unsupported_android_cpu(self):
        self.script("commands/uname", "echo armv7l\n")
        result = self.run_build("build")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires ARM64", result.stderr)

    def test_warm_tree_selects_android_executor_and_preserves_arguments(self):
        self.script("w_android", "exit 93\n")
        self.script("bin/wexec_android", "printf '%s\\n' \"$@\" >> calls\n")
        result = self.run_build("-j", "2", "tests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "calls").read_text().splitlines(),
                         ["wexec_android", "-j", "2", "tests"])

    def test_cold_tree_bootstraps_compiler_and_executor(self):
        self.script("w_android", '''
[ "$1" = arm64_android ] || exit 90
[ "$2" = w.w ] || exit 91
cp compiler_template "$4"
chmod +x "$4"
''')
        self.script("compiler_template", '''
[ "$1" = arm64_android ] || exit 92
[ "$2" = tools/wexec_main.w ] || exit 93
cp executor_template "$4"
chmod +x "$4"
''')
        self.script("executor_template", "printf '%s\\n' \"$@\" >> calls\n")
        result = self.run_build("verify_android")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "bin/wv2_android").exists())
        self.assertEqual((self.root / "calls").read_text().splitlines(),
                         ["wexec_android", "verify_android"])


if __name__ == "__main__":
    unittest.main()
