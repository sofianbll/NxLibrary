import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check_selene_tokens.py"
SPEC = importlib.util.spec_from_file_location("check_selene_tokens", SCRIPT)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class SeleneTokenChecks(unittest.TestCase):
    def test_numeric_arguments_including_multiline_and_scaled(self):
        text = """view.font(
            .system(size: canvas.u(20), weight: .bold))
            .padding(.top,
                -8).padding(12)
            .cornerRadius(6)
        RoundedRectangle(cornerRadius: 8)"""
        self.assertEqual(
            list(check.literals(text)),
            [(".font(.system(size:canvas.u(20", 1), (".padding(.top,-8", 3),
             (".padding(12", 4), ("cornerRadius(6", 5), ("cornerRadius:8", 6)],
        )

    def test_comments_strings_and_token_references_are_not_counted(self):
        text = '''// .seleneFont(12)
        /* .padding(8) */ let source = ".cornerRadius(2)"
        view.seleneFont(.caption).padding(canvas.u(SeleneTokens.Space.small))'''
        self.assertEqual(list(check.literals(text)), [])
