"""Image assembly tests require no root privileges, network, or VM."""
import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("wvm_image", Path(__file__).parents[1] / "tools/wvm_image.py")
image = importlib.util.module_from_spec(spec)
spec.loader.exec_module(image)


class ImageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.init = self.root / "init"
        self.init.write_bytes(b"\x7fELF\x02\x01" + bytes(12) + b"\x3e\0" + bytes(44))

    def archive(self, members):
        path = self.root / "rootfs.tar"
        with tarfile.open(path, "w") as tar:
            for name, data, kind in members:
                member = tarfile.TarInfo(name)
                member.mode = 0o4755
                member.mtime = 1234567
                if kind == "link":
                    member.type = tarfile.SYMTYPE
                    member.linkname = data
                    tar.addfile(member)
                else:
                    member.size = len(data)
                    tar.addfile(member, io.BytesIO(data))
        return path, image.digest_file(path)

    def test_reproducible_and_pinned(self):
        path, digest = self.archive([("bin/tool", b"hello", "file"), ("bin/sh", "tool", "link")])
        first, second = self.root / "a.cpio", self.root / "b.cpio"
        a = image.build(path, digest, self.init, first)
        b = image.build(path, digest, self.init, second)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(a, b)
        self.assertIn(b"dev/console\0", first.read_bytes())
        self.assertEqual(a["image_sha256"], hashlib.sha256(first.read_bytes()).hexdigest())
        with self.assertRaisesRegex(ValueError, "SHA256"):
            image.build(path, "0" * 64, self.init, first)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_unsafe_paths_and_symlink_ancestors(self):
        for members in ([('../escape', b'x', 'file')],
                        [('/escape', b'x', 'file')],
                        [('bin', '/host', 'link'), ('bin/tool', b'x', 'file')],
                        [('proc', '/host', 'link')],
                        [('same', b'a', 'file'), ('same', b'b', 'file')],
                        [('TRAILER!!!', b'x', 'file')],
                        [('init/evil', b'x', 'file')],
                        [('dev/console/evil', b'x', 'file')]):
            with self.subTest(members=members):
                path, digest = self.archive(members)
                with self.assertRaises(ValueError):
                    image.build(path, digest, self.init, self.root / 'bad.cpio')
                self.assertFalse((self.root / 'bad.cpio').exists())

    def test_failed_init_keeps_previous_output(self):
        path, digest = self.archive([('bin/tool', b'x', 'file')])
        self.init.write_bytes(b'not an ELF')
        output = self.root / 'image'
        output.write_bytes(b'previous')
        with self.assertRaisesRegex(ValueError, 'ELF'):
            image.build(path, digest, self.init, output)
        self.assertEqual(output.read_bytes(), b'previous')


if __name__ == '__main__':
    unittest.main()
