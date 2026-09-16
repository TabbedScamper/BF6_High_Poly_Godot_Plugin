"""Check that shared menu availability describes implemented adapter bindings."""
import copy
import unittest
from sync_shared_menu import PRODUCT, read_json, validate_capabilities, check_adapter_sources, validate_preparation


class MenuCapabilities(unittest.TestCase):
    def setUp(self):
        self.menu = read_json(PRODUCT / "shared/menu/menu.json")
        self.capabilities = read_json(PRODUCT / "shared/menu/adapters.json")

    def test_real_supported_sets_and_godot_source(self):
        validate_capabilities(self.menu, self.capabilities)
        check_adapter_sources(self.capabilities, PRODUCT / "addons/highpoly_toggle/highpoly_toggle.gd")

    def test_aspirational_unreal_control_is_rejected(self):
        for key in ("isolate_selected", "backdrops", "fx", "shadows", "lighting"):
            with self.subTest(key=key):
                menu = copy.deepcopy(self.menu)
                menu["controls"][key]["engines"].append("unreal")
                with self.assertRaisesRegex(ValueError, "unsupported"):
                    validate_capabilities(menu, self.capabilities)

    def test_wrong_action_kinds_are_rejected(self):
        for key in ("wind", "performance"):
            with self.subTest(key=key):
                menu = copy.deepcopy(self.menu)
                menu["controls"][key]["kind"] = "action"
                with self.assertRaisesRegex(ValueError, "wrong_kind"):
                    validate_capabilities(menu, self.capabilities)

    def test_preparation_weights_and_negative_controls(self):
        real = read_json(PRODUCT / "shared/menu/preparation.json")
        validate_preparation(real)
        for weight in (float("nan"), float("inf"), -1, 0.9):
            with self.subTest(weight=weight):
                changed = copy.deepcopy(real)
                changed["phases"][0]["weight"] = weight
                with self.assertRaises(ValueError):
                    validate_preparation(changed)


if __name__ == "__main__":
    unittest.main()
