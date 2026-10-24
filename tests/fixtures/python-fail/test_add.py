import unittest

from fixture_pkg import add


class AddTest(unittest.TestCase):
    def test_planted_failure(self) -> None:
        # Planted: a failing test the gate must catch.
        self.assertEqual(add(2, 2), 5)


if __name__ == "__main__":
    unittest.main()
