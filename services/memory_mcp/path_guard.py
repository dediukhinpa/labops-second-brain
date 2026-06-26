"""Path safety guard for vault filesystem operations."""
from pathlib import Path

from services.shared.scopes import ALLOWED_PATH_SCOPES, normalize_scope

# Back-compat alias for importers; the canonical set lives in services.shared.scopes.
ALLOWED_SCOPES = ALLOWED_PATH_SCOPES


def validate_path(path: str, vault_root: str) -> Path:
    """Validate and resolve a vault-relative path.

    Args:
        path: Relative path within the vault (e.g. 'decisions/my-note.md'). Legacy
            numbered prefixes ('30-decisions/...') are accepted and rewritten to
            the canonical semantic folder during the migration window.
        vault_root: Absolute path to the vault root directory.

    Returns:
        Resolved absolute Path within the vault.

    Raises:
        ValueError: If the path is unsafe or targets an unknown scope.
    """
    if not path:
        raise ValueError("Path must not be empty")

    if ".." in path:
        raise ValueError(f"Path traversal blocked: '..' in '{path}'")

    if "~" in path:
        raise ValueError(f"Home expansion blocked: '~' in '{path}'")

    if path.startswith("/"):
        raise ValueError(f"Absolute paths blocked: '{path}'")

    # Extract top-level scope, accepting legacy numbered names via the alias map.
    top_level = path.split("/")[0]
    canonical = normalize_scope(top_level)
    if canonical not in ALLOWED_PATH_SCOPES:
        raise ValueError(
            f"Unknown scope '{top_level}'. "
            f"Allowed: {', '.join(sorted(ALLOWED_PATH_SCOPES))}"
        )
    # Rewrite a legacy prefix so the file lands in the canonical semantic folder.
    if canonical != top_level:
        rest = path.split("/", 1)[1] if "/" in path else ""
        path = f"{canonical}/{rest}" if rest else canonical

    root = Path(vault_root).resolve()
    resolved = (root / path).resolve()

    # Final containment check -- resolved path must be under vault_root
    if not str(resolved).startswith(str(root) + "/") and resolved != root:
        raise ValueError(
            f"Path '{path}' resolves outside vault root"
        )

    return resolved
