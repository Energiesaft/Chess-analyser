"""Tests for the documented input format accepted by the current stack.

Current contract: whitespace-separated board squares (e.g. e2 e4 e7 e5).
These are format tests, not a full legal-chess-move validator.
"""
from pathlib import Path
import pytest

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"


def tokens_are_valid_square_format(text: str) -> bool:
    moves = text.split()
    return bool(moves) and len(moves) <= 5000 and all(
        len(move) == 2
        and move[0].lower() in "abcdefgh"
        and move[1] in "12345678"
        for move in moves
    )


@pytest.mark.parametrize("name", [
    "gueltig_10_zuege.txt",
    "gueltig_20_zuege.txt",
    "gueltig_30_zuege.txt",
    "gueltig_40_zuege.txt",
])
def test_valid_fixture_format(name):
    text = (FIXTURES / name).read_text(encoding="utf-8-sig")
    assert tokens_are_valid_square_format(text), f"Fixture should pass format check: {name}"


@pytest.mark.parametrize("name", [
    "ungueltig_feld.txt",
    "ungueltig_einzelnes_token.txt",
    "ungueltig_langnotation.txt",
    "ungueltig_mit_zugnummern.txt",
    "ungueltig_leer.txt",
    "ungueltig_zusatztext.txt",
])
def test_invalid_fixture_format(name):
    text = (FIXTURES / name).read_text(encoding="utf-8-sig")
    assert not tokens_are_valid_square_format(text), f"Fixture should fail format check: {name}"


def test_format_is_not_full_chess_legality():
    # The current Lambda checks square-token shape, not whether a move is legal.
    assert tokens_are_valid_square_format("e2 e4 e2 e4")
