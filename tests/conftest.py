"""pytest configuration for native Hy tests."""

import os
from pathlib import Path
import hy, pytest

NATIVE_TESTS = Path.cwd() / "tests/native_tests"
os.environ.pop("HYSTARTUP", None)


def pytest_collect_file(file_path, parent):
    """Collect .hy files from native_tests directory."""
    if (
        file_path.suffix == ".hy"
        and NATIVE_TESTS in file_path.parents
        and file_path.name != "__init__.hy"
    ):
        return pytest.Module.from_parent(parent, path=file_path)
