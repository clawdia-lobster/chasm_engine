"""pytest configuration for native Hy tests."""

import os
import sys
from pathlib import Path
import hy, pytest

# Set config file path before any chasm_engine imports
# This is needed because chasm_engine modules read config at import time
# The config module uses argparse which reads sys.argv
_config_path = Path(__file__).parent.parent / "milliways.toml"
if not _config_path.exists():
    _config_path = Path(__file__).parent.parent / "server.toml"

# Prepend config arg to sys.argv before any chasm_engine imports
if "-c" not in sys.argv:
    sys.argv = [sys.argv[0] or "pytest", "-c", str(_config_path)] + [a for a in sys.argv[1:] if a not in ["-v", "--assert=plain"]]

NATIVE_TESTS = Path(__file__).parent / "native_tests"
os.environ.pop("HYSTARTUP", None)


def pytest_collect_file(file_path, parent):
    """Collect .hy files from native_tests directory."""
    if (
        file_path.suffix == ".hy"
        and NATIVE_TESTS in file_path.parents
        and file_path.name != "__init__.hy"
    ):
        return pytest.Module.from_parent(parent, path=file_path)
