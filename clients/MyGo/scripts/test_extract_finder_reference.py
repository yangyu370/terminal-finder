import tempfile
import unittest
from pathlib import Path
from PIL import Image
from extract_finder_reference import extract, SOURCE_SIZE, REGIONS

class ExtractTest(unittest.TestCase):
    def test_rejects_lossy_or_resized_input(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, size in [("wrong.png", (1153, 681)), ("lossy.jpg", SOURCE_SIZE)]:
                source = root / name
                Image.new("RGB", size).save(source)
                with self.assertRaises(ValueError):
                    extract(source, root / "out")
            self.assertFalse((root / "out").exists())

    def test_fixed_crops_and_original_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.png"
            Image.new("RGBA", SOURCE_SIZE, (38, 38, 38, 255)).save(source)
            before = source.read_bytes()
            meta = extract(source, root / "out")
            self.assertEqual(source.read_bytes(), before)
            self.assertEqual(meta["devicePixelsPerPoint"], 2)
            self.assertEqual(len(meta["sourceSHA256"]), 64)
            for name, (x0, y0, x1, y1) in REGIONS.items():
                with Image.open(root / "out" / (name + ".png")) as crop:
                    self.assertEqual(crop.size, (x1-x0, y1-y0))
                    self.assertEqual(crop.getpixel((0, 0)), (38, 38, 38, 255))
            self.assertEqual(len(list((root / "out").glob("*.png"))), len(REGIONS))

if __name__ == "__main__":
    unittest.main()
