"""verbs.py: the pure parts (snap rectangles, OCR tsv, verb detection). python3 -m unittest"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from mantra_macro import verbs  # noqa: E402

TSV = ("level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n"
       "5\t1\t1\t1\t1\t1\t100\t200\t50\t20\t96\tHello\n"
       "5\t1\t1\t1\t1\t2\t160\t200\t60\t20\t95\tworld\n"
       "5\t1\t1\t1\t2\t1\t100\t300\t40\t20\t90\tSecond\n"
       "5\t1\t1\t1\t2\t2\t150\t300\t10\t20\t-1\t\n")


class Verbs(unittest.TestCase):
    def test_snap(self):
        self.assertEqual(verbs.snap_rect('left-half', 1512, 916), (0, 0, 756, 916))
        self.assertEqual(verbs.snap_rect('last-third', 1500, 900), (1000, 0, 500, 900))
        self.assertEqual(verbs.snap_rect('maximize', 1512, 916), (0, 0, 1512, 916))
        with self.assertRaises(verbs.VerbError):
            verbs.snap_rect('next-display', 1512, 916)
        with self.assertRaises(verbs.VerbError):
            verbs.snap_rect('nonsense', 1512, 916)

    def test_tsv_lines_and_offset(self):
        ls = verbs.parse_tsv(TSV, 10, 20)
        self.assertEqual([l['text'] for l in ls], ['Hello world', 'Second'])
        self.assertEqual((ls[0]['x'], ls[0]['y']), (10 + (100 + 220) // 2, 20 + 210))

    def test_verb_detection(self):
        self.assertTrue(verbs.is_verb('win-snap: Chrome | left-half | '))
        self.assertTrue(verbs.is_verb('ocr: screen | text'))
        self.assertFalse(verbs.is_verb('Click 100, 200'))
        self.assertFalse(verbs.is_verb('run: x'))

    def test_parts(self):
        self.assertEqual(verbs.parts('a | b', 3), ['a', 'b', ''])


if __name__ == '__main__':
    unittest.main()
