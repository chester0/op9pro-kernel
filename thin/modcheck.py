#!/usr/bin/env python3
"""modcheck.py - will the phone's vendor modules load into a kernel build? (the check before any boot)

The kernel is built with CONFIG_MODVERSIONS, so a module loads only if (1) its vermagic equals the kernel's
release string and flags, and (2) every symbol it imports has, in the kernel, the same CRC the module was
built against. This reads both from the modules (ELF sections .modinfo and __versions) and compares them with
the build's exported-symbol CRCs (thin/build.sh crc -> crc.txt: lines "__crc_<symbol> <hex value>").

    modcheck.py CRC_FILE MODULES_DIR --vermagic "5.4.302-levion-op9+ SMP preempt mod_unload modversions aarch64"

Prints one line per problem and a summary; exit 0 when nothing is wrong, 1 otherwise.
A symbol that is not in the kernel's CRC list is looked up in the other modules' own __crc_* symbols (modules
can export to each other); one found nowhere is "unresolved" and counts as a problem.
"""

import argparse
import struct
import sys
from dataclasses import dataclass, field
from pathlib import Path

ELF_MAGIC = b"\x7fELF"
ELFCLASS64 = 2
SHT_SYMTAB = 2
SHN_ABS = 0xFFF1
MODVERSION_ENTRY = struct.Struct("<Q56s")  # struct modversion_info on arm64 (5.4): unsigned long crc; char name[56]
SECTION_HEADER = struct.Struct("<IIQQQQIIQQ")
SYMBOL = struct.Struct("<IBBHQQ")
CRC_PREFIX = "__crc_"


@dataclass
class Result:
    symbols_checked: int = 0
    modules: int = 0
    crc_mismatches: list = field(default_factory=list)  # (module, symbol, module's crc, kernel's crc)
    vermagic_mismatches: list = field(default_factory=list)  # (module, vermagic or None)
    unresolved: list = field(default_factory=list)  # (module, symbol)

    @property
    def ok(self):
        return not (self.crc_mismatches or self.vermagic_mismatches or self.unresolved)


def _sections(data):
    """Yield (name, type, offset, size, link) of every section of an ELF64 little-endian file."""
    if data[:4] != ELF_MAGIC or data[4] != ELFCLASS64:
        raise ValueError("not an ELF64 file")
    (shoff,) = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    raw = [SECTION_HEADER.unpack_from(data, shoff + i * shentsize) for i in range(shnum)]
    names_off = raw[shstrndx][4]
    for name_idx, sh_type, _flags, _addr, offset, size, link, _info, _align, _entsize in raw:
        end = data.index(b"\0", names_off + name_idx)
        yield data[names_off + name_idx : end].decode(), sh_type, offset, size, link


def _cstring(data, start):
    return data[start : data.index(b"\0", start)].decode()


def read_vermagic(data):
    for name, _type, offset, size, _link in _sections(data):
        if name == ".modinfo":
            for item in data[offset : offset + size].split(b"\0"):
                if item.startswith(b"vermagic="):
                    return item[len(b"vermagic=") :].decode()
    return None


def read_versions(data):
    """The (symbol, crc) pairs the module imports, from its __versions section."""
    for name, _type, offset, size, _link in _sections(data):
        if name == "__versions":
            for pos in range(offset, offset + size, MODVERSION_ENTRY.size):
                crc, raw_name = MODVERSION_ENTRY.unpack_from(data, pos)
                yield raw_name.split(b"\0", 1)[0].decode(), crc


def read_exports(data):
    """The {symbol: crc} a module exports, from its absolute __crc_<symbol> symbols."""
    sections = list(_sections(data))
    exports = {}
    for _name, sh_type, offset, size, link in sections:
        if sh_type != SHT_SYMTAB:
            continue
        str_offset = sections[link][2]
        for pos in range(offset, offset + size, SYMBOL.size):
            st_name, _info, _other, shndx, value, _size = SYMBOL.unpack_from(data, pos)
            if shndx == SHN_ABS and st_name:
                sym = _cstring(data, str_offset + st_name)
                if sym.startswith(CRC_PREFIX):
                    exports[sym[len(CRC_PREFIX) :]] = value & 0xFFFFFFFF
    return exports


def read_crc_file(path):
    """{symbol: crc} from thin/build.sh crc output: lines '__crc_<symbol> <hex value>'."""
    crcs = {}
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].startswith(CRC_PREFIX):
            crcs[parts[0][len(CRC_PREFIX) :]] = int(parts[1], 16) & 0xFFFFFFFF
    return crcs


def check_modules(modules_dir, kernel_crcs, vermagic):
    """Compare every *.ko in modules_dir with the kernel's CRCs and vermagic."""
    result = Result()
    loaded = {path.name: path.read_bytes() for path in sorted(Path(modules_dir).glob("*.ko"))}
    module_exports = {}
    for data in loaded.values():
        module_exports.update(read_exports(data))
    for name, data in loaded.items():
        result.modules += 1
        found = read_vermagic(data)
        if found != vermagic:
            result.vermagic_mismatches.append((name, found))
        for symbol, crc in read_versions(data):
            result.symbols_checked += 1
            expected = kernel_crcs.get(symbol, module_exports.get(symbol))
            if expected is None:
                result.unresolved.append((name, symbol))
            elif expected != (crc & 0xFFFFFFFF):
                result.crc_mismatches.append((name, symbol, crc, expected))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("crc_file", help="crc.txt from 'thin/build.sh crc'")
    parser.add_argument("modules_dir", help="folder with the phone's vendor_dlkm *.ko files")
    parser.add_argument("--vermagic", required=True, help="the full vermagic string the running kernel expects")
    args = parser.parse_args(argv)
    result = check_modules(args.modules_dir, read_crc_file(args.crc_file), args.vermagic)
    for module, found in result.vermagic_mismatches:
        print(f"VERMAGIC {module}: {found!r}, kernel expects {args.vermagic!r}")
    for module, symbol, have, want in result.crc_mismatches:
        print(f"CRC {module}: {symbol} module has {have:#010x}, kernel has {want:#010x}")
    for module, symbol in result.unresolved:
        print(f"UNRESOLVED {module}: {symbol} is exported by no module and is not in the kernel's CRC list")
    print(
        f"{'PASS' if result.ok else 'FAIL'}: {result.modules} modules, {result.symbols_checked} imported symbols, "
        f"{len(result.vermagic_mismatches)} vermagic, {len(result.crc_mismatches)} CRC, {len(result.unresolved)} unresolved"
    )
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main())
