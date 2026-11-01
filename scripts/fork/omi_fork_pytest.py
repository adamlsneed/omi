"""Test-only fork adaptations; upstream source and assertions stay unchanged."""

import jinja2  # Preload the real dependency before legacy tests install an optional stub.
import pytest

from watch_task_source import install_manifest_loader

_original_loader = None


@pytest.hookimpl(tryfirst=True)
def pytest_pycollect_makemodule(module_path, parent):
    global _original_loader
    if module_path.name != 'test_task_intelligence_contract_freeze.py' or _original_loader is not None:
        return None
    # Import after the backend's conftest has installed its hermetic dependency fixtures.
    import utils.task_intelligence.contracts as contracts

    _original_loader = install_manifest_loader(contracts)
    return None


def pytest_unconfigure(config):
    global _original_loader
    if _original_loader is not None:
        import utils.task_intelligence.contracts as contracts

        contracts.load_source_manifest = _original_loader
        _original_loader = None
