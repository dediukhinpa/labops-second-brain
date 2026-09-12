"""Тесты установочных скриптов — на два молчаливых класса отказов.

Оба чинились 12.09.2026 после установки у клиента:

* `install.sh` поднимал сервисы через `systemctl enable --now`, а тот не трогает
  УЖЕ РАБОТАЮЩИЙ юнит. После повторной установки в /opt лежал новый код, а в
  памяти крутился старый — и `status` в конце честно показывал «active», так что
  установка выглядела обновлённой, ничего не обновив;
* `verify.sh` глушил вывод своих проверок в /dev/null, и красная строка не
  говорила, что именно не сошлось: оператор запускал проверку заново вручную.
"""
import re
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent / "scripts"

# Юниты, которые установщик поднимает и обязан перезапускать.
SERVICE_UNITS = (
    "second_brain-memory-mcp",
    "second_brain-memory_router-mcp",
    "second_brain-agent_router-mcp",
    "second_brain-agent_router-worker",
    "second_brain-ingest-worker",
)


def _read(name: str) -> str:
    """Прочитать скрипт из scripts/."""
    return (SCRIPTS / name).read_text(encoding="utf-8")


def test_install_restarts_services_it_enables() -> None:
    """Установка обязана перезапустить сервисы, а не только включить автозапуск."""
    text = _read("install.sh")
    restart = re.search(r"systemctl restart\s+((?:\\\n\s*\S+\s*)+)", text)
    assert restart is not None, "install.sh не перезапускает свои юниты"
    block = restart.group(1)
    missing = [u for u in SERVICE_UNITS if u not in block]
    assert not missing, f"эти юниты не перезапускаются после установки: {missing}"


def test_install_does_not_rely_on_enable_now_alone() -> None:
    """`enable --now` сам по себе оставил бы работающие сервисы на старом коде."""
    text = _read("install.sh")
    enable_now = re.search(
        r"systemctl enable --now\s+\\\n\s*second_brain-memory-mcp", text
    )
    assert enable_now is None, (
        "сервисы снова поднимаются одним `enable --now` — работающий юнит "
        "не подхватит новый код из /opt"
    )


@pytest.mark.parametrize("probe", ["check_env_sync.py", "-m pytest"])
def test_verify_does_not_mute_its_probes(probe: str) -> None:
    """Причина провала должна попадать в вывод verify.sh, а не в /dev/null."""
    text = _read("verify.sh")
    for line in text.splitlines():
        if probe in line and ">/dev/null 2>&1" in line:
            pytest.fail(f"вывод проверки заглушён: {line.strip()}")


def test_verify_prints_the_failing_output() -> None:
    """Хвост вывода упавшей проверки печатается — иначе «провалено» без причины."""
    text = _read("verify.sh")
    assert text.count('tail -n "$VERIFY_TAIL"') >= 2, (
        "verify.sh не показывает вывод упавших проверок"
    )
