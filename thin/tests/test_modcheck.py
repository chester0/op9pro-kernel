"""Tests for thin/modcheck.py: does a kernel build's exported-symbol CRC list match the phone's vendor modules?

Run:  python -I -m unittest thin/tests/test_modcheck.py   (from the repo root)

The modules here are tiny ELF64 files built in memory: .modinfo (vermagic), __versions (the CRCs the module
expects) and .symtab (the __crc_* symbols a module that exports symbols carries).
"""

import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import modcheck  # noqa: E402

VERMAGIC = "5.4.302-levion-op9+ SMP preempt mod_unload modversions aarch64"


def build_ko(vermagic=VERMAGIC, versions=(), exports=()):
    """Return the bytes of a minimal ELF64 little-endian .ko. versions: (name, crc); exports: (name, crc)."""
    modinfo = b"" if vermagic is None else f"vermagic={vermagic}".encode() + b"\0"
    # struct modversion_info: unsigned long crc (8 bytes), char name[56]
    vers = b"".join(struct.pack("<Q56s", crc, name.encode()) for name, crc in versions)
    strtab = b"\0"
    symtab = struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)
    for name, crc in exports:
        symtab += struct.pack("<IBBHQQ", len(strtab), 0x11, 0, 0xFFF1, crc, 0)  # SHN_ABS
        strtab += f"__crc_{name}".encode() + b"\0"
    names = [b"", b".modinfo", b"__versions", b".symtab", b".strtab", b".shstrtab"]
    shstr = b"".join(n + b"\0" for n in names)
    offsets, pos = [], 0
    for n in names:
        offsets.append(pos)
        pos += len(n) + 1
    blobs = [b"", modinfo, vers, symtab, strtab, shstr]
    types = [0, 1, 1, 2, 3, 3]
    body, data_off, cur = b"", [], 64
    for blob in blobs:
        data_off.append(cur)
        body += blob
        cur += len(blob)
    shoff = cur
    headers = b""
    for i, blob in enumerate(blobs):
        link = 4 if types[i] == 2 else 0
        entsize = 24 if types[i] == 2 else 0
        headers += struct.pack("<IIQQQQIIQQ", offsets[i], types[i], 0, 0, data_off[i], len(blob), link, 0, 1, entsize)
    ehdr = (
        b"\x7fELF\x02\x01\x01"
        + b"\0" * 9
        + struct.pack("<HHIQQQIHHHHHH", 1, 183, 1, 0, 0, shoff, 0, 64, 0, 0, 64, 6, 5)
    )
    return ehdr + body + headers


class ModcheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        self.crcs = {"printk": 0x11111111, "kmalloc": 0x22222222}

    def write_module(self, name, **kwargs):
        (self.dir / f"{name}.ko").write_bytes(build_ko(**kwargs))

    def check(self, **kwargs):
        return modcheck.check_modules(self.dir, self.crcs, VERMAGIC, **kwargs)

    def test_matching_module_passes(self):
        self.write_module("good", versions=[("printk", 0x11111111), ("kmalloc", 0x22222222)])
        result = self.check()
        self.assertEqual(result.crc_mismatches, [])
        self.assertEqual(result.vermagic_mismatches, [])
        self.assertEqual(result.unresolved, [])
        self.assertEqual(result.symbols_checked, 2)

    def test_wrong_crc_is_reported_with_both_values(self):
        self.write_module("bad", versions=[("printk", 0x99999999)])
        result = self.check()
        self.assertEqual(result.crc_mismatches, [("bad.ko", "printk", 0x99999999, 0x11111111)])

    def test_wrong_vermagic_is_reported(self):
        self.write_module("old", vermagic="5.4.302-qgki SMP preempt mod_unload modversions aarch64")
        result = self.check()
        self.assertEqual([m[0] for m in result.vermagic_mismatches], ["old.ko"])

    def test_module_without_vermagic_is_reported_not_skipped(self):
        self.write_module("nomagic", vermagic=None)
        result = self.check()
        self.assertEqual(result.vermagic_mismatches, [("nomagic.ko", None)])

    def test_symbol_exported_by_another_module_is_resolved_there(self):
        self.write_module("provider", exports=[("helper", 0x33333333)])
        self.write_module("user", versions=[("helper", 0x33333333)])
        result = self.check()
        self.assertEqual(result.unresolved, [])
        self.assertEqual(result.crc_mismatches, [])

    def test_symbol_exported_nowhere_is_unresolved(self):
        self.write_module("user", versions=[("nobody_exports_this", 0x44444444)])
        result = self.check()
        self.assertEqual(result.unresolved, [("user.ko", "nobody_exports_this")])

    def test_crc_file_parser_reads_llvm_nm_pairs(self):
        crc_file = self.dir / "crc.txt"
        crc_file.write_text("__crc_printk 0000000011111111\n__crc_kmalloc 0000000022222222\nnot a crc line\n")
        self.assertEqual(modcheck.read_crc_file(crc_file), self.crcs)

    def test_main_exit_code_follows_the_verdict(self):
        crc_file = self.dir / "crc.txt"
        crc_file.write_text("__crc_printk 0000000011111111\n")
        mods = self.dir / "mods"
        mods.mkdir()
        (mods / "m.ko").write_bytes(build_ko(versions=[("printk", 0x11111111)]))
        self.assertEqual(modcheck.main([str(crc_file), str(mods), "--vermagic", VERMAGIC]), 0)
        (mods / "m.ko").write_bytes(build_ko(versions=[("printk", 0x1)]))
        self.assertEqual(modcheck.main([str(crc_file), str(mods), "--vermagic", VERMAGIC]), 1)


if __name__ == "__main__":
    unittest.main()
