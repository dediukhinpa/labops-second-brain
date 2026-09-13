"""Тесты установочных скриптов — на два молчаливых класса отказов.

Оба чинились 12.09.2026 после установки у клиента:

* `install.sh` поднимал сервисы через `systemctl enable --now`, а тот не трогает
  УЖЕ РАБОТАЮЩИЙ юнит. После повторной установки в /opt лежал новый код, а в
  памяти крутился старый — и `status` в конце честно показывал «active», так что
  установка выглядела обновлённой, ничего не обновив;
* `verify.sh` глушил вывод своих проверок в /dev/null, и красная строка не
  говорила, что именно не сошлось: оператор запускал проверку заново вручную.

И три, найденные 13.09.2026 прогоном установки на чистой Ubuntu 26.04 (сама
установка прошла, а гейт `verify.sh` — нет):

* проверка токена слала одиночный `tools/list` без сессии, сервер отвечал 400
  «Missing session ID» при любом токене — гейт был красным на каждом хосте;
* `task-mcp` юнит ставился, но не включался, а verify его требовал;
* проверки живости открывали MCP-сессии и бросали их до таймаута простоя.
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
    "second_brain-task-mcp",
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


def test_install_enables_task_mcp() -> None:
    """Доска задач поднимается установкой, а не руками после неё."""
    text = _read("install.sh")
    enable = re.search(r"systemctl enable\s+((?:\\\n\s*\S+\s*)+)", text)
    assert enable is not None and "second_brain-task-mcp" in enable.group(1), (
        "install.sh не включает second_brain-task-mcp — доска задач не поднимется"
    )


def test_verify_requires_task_mcp() -> None:
    """task-mcp проверяется всегда, а не «если юнит найден»."""
    text = _read("verify.sh")
    block = re.search(r"MCP_ENDPOINTS=\((.*?)\n\)", text, flags=re.S)
    assert block is not None and "second_brain-task-mcp:5003" in block.group(1)


def test_verify_auth_probe_uses_a_session_and_closes_it() -> None:
    """tools/list — внутри сессии, сессия закрывается, токен не в argv curl."""
    text = _read("verify.sh")
    probe = re.search(r"mcp_session_tools_list\(\) \{(.*?)\n\}", text, flags=re.S)
    assert probe is not None, "нет сессионной проверки tools/list"
    body = probe.group(1)
    for step in ("$init", "notifications/initialized",
                 "tools/list", "-X DELETE", "Mcp-Session-Id"):
        assert step in body, f"в сессионной проверке нет шага: {step}"
    assert not re.search(r'-H "Authorization: Bearer', text), "токен снова уходит аргументом curl"


@pytest.mark.parametrize("name", ["verify.sh", "smoke-test.sh"])
def test_liveness_probes_close_their_sessions(name: str) -> None:
    """initialize открывает сессию — проверка обязана её закрыть."""
    text = _read(name)
    assert "-X DELETE" in text and "Mcp-Session-Id" in text, (
        f"{name} открывает MCP-сессии и не закрывает их"
    )
    assert not re.search(r'-H "Authorization: Bearer', text), f"{name}: токен в argv curl"


def test_smoke_probes_task_mcp() -> None:
    """Смоук после установки видит и доску задач."""
    text = _read("smoke-test.sh")
    assert '"tasks:http://127.0.0.1:${MCP_TASK_PORT}/mcp"' in text


@pytest.mark.parametrize("name", ["install.sh", "connect-agents.sh"])
def test_service_user_commands_do_not_use_sudo_preserve_env(name: str) -> None:
    """Команды от сервисного пользователя — без sudo -E.

    Обычный sudo (22.04/24.04) с -E сохраняет HOME=/root: huggingface_hub
    под second_brain лез в /root/.cache/huggingface/token, модель не
    скачивалась, и чистая установка на 24.04 падала на шаге 11 (13.09.2026).
    sudo-rs (26.04) -E игнорирует — поэтому на 26.04 та же установка проходила.
    """
    code = "\n".join(
        line for line in _read(name).splitlines() if not line.lstrip().startswith("#")
    )
    assert not re.search(r"sudo\s+-E\b", code), f"{name}: sudo -E вернулся"
    assert "PGPASSWORD=" not in code, f"{name}: пароль БД снова идёт через окружение/argv"
