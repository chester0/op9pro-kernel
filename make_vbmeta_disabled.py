#!/usr/bin/env python3
"""
Generate a minimal unsigned AVB vbmeta.img with verification and hashtree
DISABLED. Bootloader (unlocked) treats DISABLE_VERIFICATION=2 as "skip all
chain-of-trust checks", so boot_b can be our modified v8 without matching a
signed descriptor.

AVB vbmeta header layout (256 bytes, big-endian except release_string):
  0x00  magic                                  4  "AVB0"
  0x04  required_libavb_version_major          4  1
  0x08  required_libavb_version_minor          4  0
  0x0C  authentication_data_block_size         8  0
  0x14  auxiliary_data_block_size              8  0
  0x1C  algorithm_type                         4  0 (none)
  0x20  hash_offset                            8  0
  0x28  hash_size                              8  0
  0x30  signature_offset                       8  0
  0x38  signature_size                         8  0
  0x40  public_key_offset                      8  0
  0x48  public_key_size                        8  0
  0x50  public_key_metadata_offset             8  0
  0x58  public_key_metadata_size               8  0
  0x60  descriptors_offset                     8  0
  0x68  descriptors_size                       8  0
  0x70  rollback_index                         8  0
  0x78  flags                                  4  3  <-- HASHTREE_DISABLED|VERIFICATION_DISABLED
  0x7C  rollback_index_location                4  0
  0x80  release_string                        48  "avbtool 1.3.0" (zero-padded)
  0xB0  reserved                              80  zeros
  -> total 256 bytes
"""
import struct
from pathlib import Path

AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED = 1
AVB_VBMETA_IMAGE_FLAGS_VERIFICATION_DISABLED = 2

flags = AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED | AVB_VBMETA_IMAGE_FLAGS_VERIFICATION_DISABLED

header = bytearray(256)
header[0:4] = b"AVB0"
struct.pack_into(">I", header, 0x04, 1)            # major
struct.pack_into(">I", header, 0x08, 0)            # minor
# all size/offset fields already zero
struct.pack_into(">I", header, 0x1C, 0)            # algorithm = none
struct.pack_into(">I", header, 0x78, flags)        # flags = 3
struct.pack_into(">I", header, 0x7C, 0)            # rollback_index_location
rel = b"avbtool 1.3.0"
header[0x80:0x80 + len(rel)] = rel

out = Path("C:/000CHESTA-CODE/op9pro-kernel/output/vbmeta_disabled.img")
out.write_bytes(bytes(header))
print(f"wrote {out} ({len(header)} bytes, flags=0x{flags:02x})")
