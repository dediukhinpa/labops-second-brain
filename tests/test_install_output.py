"""Единый вид вывода установочных скриптов.

До 13.09.2026 у каждого скрипта был свой формат: «[install 12:00:00Z] …»,
«[connect-agents WARN] …», «PASS/WARN/FAIL» в verify.sh, а предупреждения
install.sh шли обычным текстом «log "WARNING: …"» и терялись среди вывода apt и
pip. Оператор ставит second-brain сразу после labops-ai-assistant, поэтому
значки и цвета взяты оттуда: scripts/lib/ui.sh — копия
agent-architecture/orchestration/lib/ui.sh.
"""
import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "scripts"
UI = SCRIPTS / "lib" / "ui.sh"
# Оригинал блока — в соседнем checkout монорепо, если он есть на машине.
UPSTREAM_UI = (
    REPO.parent / "labops-ai-assistant" / "agent-architecture" / "orchestration" / "lib" / "ui.sh"
)
# Скрипты, которые печатают ход установки или проверки.
OUTPUT_SCRIPTS = (
    "install.sh",
    "migrate.sh",
    "smoke-test.sh",
    "connect-agents.sh",
    "verify.sh",
    "install-local.sh",
    "install-vps.sh",
)


def _block(path: Path) -> str:
    """Вернуть блок функций между метками ui:begin и ui:end."""
    text = path.read_text(encoding="utf-8")
    match = re.search(r"^# ui:begin.*?^# ui:end$", text, flags=re.M | re.S)
    assert match is not None, f"в {path} нет блока ui:begin … ui:end"
    return match.group(0)


def _bash(script: str) -> subprocess.CompletedProcess[str]:
    """Выполнить bash-фрагмент с подключённым ui.sh."""
    return subprocess.run(
        ["bash", "-c", f'source "{UI}"; {script}'],
        capture_output=True,
        text=True,
        input="",
        timeout=10,
        check=False,
    )


def test_ui_block_matches_upstream() -> None:
    """Копия не должна разойтись с оригиналом в labops-ai-assistant."""
    if not UPSTREAM_UI.is_file():
        pytest.skip("labops-ai-assistant рядом не найден — сверять не с чем")
    assert _block(UI) == _block(UPSTREAM_UI), (
        "scripts/lib/ui.sh разошёлся с agent-architecture/orchestration/lib/ui.sh"
    )


@pytest.mark.parametrize(
    ("call", "marker", "stream"),
    [
        ("say x", "▶ x", "stdout"),
        ("ok x", "✓ x", "stdout"),
        ("warn x", "⚠ x", "stdout"),
        ("step x", "→ x", "stdout"),
        ("note x", "ℹ x", "stdout"),
        ("err x", "✗ x", "stderr"),
    ],
)
def test_markers(call: str, marker: str, stream: str) -> None:
    """У каждого уровня свой значок; ошибки уходят в stderr."""
    result = _bash(call)
    assert marker in getattr(result, stream)


def test_die_exits_nonzero() -> None:
    """die печатает ✗ в stderr и завершает скрипт."""
    result = _bash("die boom; echo alive")
    assert result.returncode != 0
    assert "✗ boom" in result.stderr
    assert "alive" not in result.stdout


@pytest.mark.parametrize("name", OUTPUT_SCRIPTS)
def test_scripts_use_shared_output(name: str) -> None:
    """Скрипт подключает ui.sh и не держит своих цветов, префиксов и вопросов."""
    text = (SCRIPTS / name).read_text(encoding="utf-8")
    assert 'lib/ui.sh"' in text, f"{name} не подключает scripts/lib/ui.sh"
    code = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#")
    )
    leftovers = {
        "своя функция log": r"^\s*log\(\)",
        "префикс [script …]": r"'\[(install|migrate|smoke|connect-agents|install-local|install-vps)[ \]]",
        "log \"WARNING: …\"": r'log "WARNING',
        "свои escape-коды": r"\\033\[|\$'\\e\[",
        "read -p вместо ask_text/ask_yn": r"read -r -p ",
        "подсказка [y/N] / [Y/n]": r"\[y/N\]|\[Y/n\]",
    }
    found = [what for what, pattern in leftovers.items() if re.search(pattern, code, flags=re.M)]
    assert not found, f"{name}: остался свой вид вывода: {found}"
