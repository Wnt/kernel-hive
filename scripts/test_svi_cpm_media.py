"""ImageDisk physical-order regression without proprietary media."""

import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "svi_cpm_media", Path(__file__).parent / "build-guests/lib/svi_cpm_media.py"
)
assert SPEC is not None and SPEC.loader is not None
MEDIA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MEDIA)


def synthetic_disk():
    image = bytearray(b"IMD synthetic regression\r\n\x1a")
    for cylinder in range(40):
        for head in range(2):
            first = (cylinder, head) == (0, 0)
            size = 128 if first else 256
            image.extend(bytes([2 if first else 5, cylinder, head, 3, 0 if first else 1]))
            image.extend(bytes([3, 1, 2]))
            image.extend(b"\x01" + bytes((n * 17) % 256 for n in range(size)))
            image.extend(b"\x01" + bytes(n % 256 for n in range(size)))
            image.extend(b"\x02\xe5")
    return bytes(image)


def physical_headers(image):
    cursor = image.index(0x1A) + 1
    headers = []
    kinds = []
    while cursor < len(image):
        _, _, _, count, size_code = image[cursor : cursor + 5]
        headers.append(image[cursor : cursor + 5 + count])
        cursor += 5 + count
        track_kinds = []
        for _ in range(count):
            kind = image[cursor]
            track_kinds.append(kind)
            cursor += 1 + ((128 << size_code) if kind == 1 else 1)
        kinds.append(track_kinds)
    return headers, kinds


class ImageDiskPhysicalOrderTests(unittest.TestCase):
    def test_overlay_preserves_unsorted_sector_ids_and_mixed_encodings(self):
        source = synthetic_disk()
        logical = MEDIA.decode_imd(source)
        overlay = dict(logical)
        original = logical[3, 1]
        overlay[3, 1] = b"Z" * 256 + bytes((n * 7) % 256 for n in range(256)) + original[512:]

        encoded = MEDIA.encode_imd(source, overlay)

        self.assertEqual(MEDIA.decode_imd(encoded), overlay)
        source_headers, source_kinds = physical_headers(source)
        encoded_headers, encoded_kinds = physical_headers(encoded)
        self.assertEqual(encoded_headers, source_headers)
        self.assertTrue(all(header[-3:] == bytes([3, 1, 2]) for header in encoded_headers))
        self.assertEqual(source_kinds[7], [1, 1, 2])
        self.assertEqual(encoded_kinds[7], [1, 2, 1])
        self.assertEqual(encoded.split(b"\x1a", 1)[0], source.split(b"\x1a", 1)[0])


if __name__ == "__main__":
    unittest.main()
