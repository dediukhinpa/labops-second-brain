"""Запускает shell-тесты из scripts/ вместе с pytest.

Без этого *.test.sh гонялись только вручную, и установщик мог сломаться, не
уронив ни одного теста.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SHELL_TESTS = sorted((REPO_ROOT / "scripts").rglob("*.test.sh"))
SHELL_TEST_TIMEOUT_SECONDS = 120


@pytest.mark.parametrize("script", SHELL_TESTS, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_shell_script(script: Path) -> None:
    """Shell-тест завершается с кодом 0.

    Args:
        script: Путь к *.test.sh.
    """
    result = subprocess.run(
        ["bash", str(script)],
        capture_output=True,
        text=True,
        timeout=SHELL_TEST_TIMEOUT_SECONDS,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
