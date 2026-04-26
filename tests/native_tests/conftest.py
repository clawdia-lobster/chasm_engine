"""Pytest fixtures for chasm_engine native tests."""

import pytest
import tempfile
import shutil
import sqlite3
from pathlib import Path


@pytest.fixture
def temp_db_path():
    """Create a temporary database file for testing."""
    temp_dir = tempfile.mkdtemp()
    db_path = Path(temp_dir) / "test.sqlite"
    yield str(db_path)
    # Cleanup
    shutil.rmtree(temp_dir, ignore_errors=True)


@pytest.fixture
def facts_db(monkeypatch, temp_db_path):
    """Set up a temporary facts database for testing."""
    import chasm_engine.facts
    
    # Store original get-db function
    original_get_db = chasm_engine.facts.get_db
    
    def test_get_db():
        """Return connection to test database."""
        conn = sqlite3.connect(temp_db_path)
        conn.row_factory = sqlite3.Row
        return conn
    
    # Monkey-patch the get-db function
    monkeypatch.setattr(chasm_engine.facts, "get_db", test_get_db)
    
    # Initialise schema
    chasm_engine.facts.init_schema()
    
    yield temp_db_path
    
    # Restore original function
    monkeypatch.setattr(chasm_engine.facts, "get_db", original_get_db)


@pytest.fixture
def quest_defs_reset():
    """Reset quest definitions before each test."""
    import chasm_engine.quest
    import chasm_engine.state
    
    # Store original state
    original_defs = dict(chasm_engine.quest.quest_defs)
    original_prog = dict(chasm_engine.quest.quest_prog)
    
    # Clear for test
    chasm_engine.quest.quest_defs.clear()
    chasm_engine.quest.quest_prog.clear()
    
    yield
    
    # Restore original state
    chasm_engine.quest.quest_defs.clear()
    chasm_engine.quest.quest_defs.update(original_defs)
    chasm_engine.quest.quest_prog.clear()
    chasm_engine.quest.quest_prog.update(original_prog)


@pytest.fixture
def sample_quests(quest_defs_reset):
    """Load sample quest definitions for testing."""
    import chasm_engine.quest
    
    test_quests = {
        "test-quest": {
            "id": "test-quest",
            "name": "Test Quest",
            "description": "A quest for testing",
            "stages": [
                {"id": "stage1", "condition": "find the key", "description": "Find the golden key", "optional": False},
                {"id": "stage2", "condition": "open the door", "description": "Open the mysterious door", "optional": False}
            ],
            "prerequisites": [],
            "rewards": {"score": 10, "items": ["potion"], "unlocks": []}
        },
        "chain-quest": {
            "id": "chain-quest",
            "name": "Chain Quest",
            "description": "Requires test-quest first",
            "stages": [
                {"id": "stage1", "condition": "talk to wizard", "description": "Talk to the wizard"}
            ],
            "prerequisites": ["test-quest"],
            "rewards": {"score": 20}
        }
    }
    
    # Populate quest_defs table
    for qid, q in test_quests.items():
        chasm_engine.quest.quest_defs[qid] = q
    
    yield test_quests
    
    # Cleanup handled by quest_defs_reset fixture
