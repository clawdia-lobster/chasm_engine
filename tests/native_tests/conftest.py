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
    import pugsql
    
    # Reset the global pugsql queries cache
    monkeypatch.setattr(chasm_engine.facts, "_facts_queries", None, raising=False)
    
    # Get the SQL path (returns path to the SQL file)
    sql_file = chasm_engine.facts.get_sql_path()
    sql_dir = str(Path(sql_file).parent)
    
    # Create a new pugsql module connected to test database
    test_queries = pugsql.module(sql_dir)
    test_queries.connect(f"sqlite:///{temp_db_path}")
    
    # Monkey-patch get_facts_queries to return our test module
    def test_get_facts_queries():
        return test_queries
    
    monkeypatch.setattr(chasm_engine.facts, "get_facts_queries", test_get_facts_queries)
    
    # Initialise schema using the test connection
    try:
        test_queries.create_table_facts()
        test_queries.create_index_facts_subject()
        test_queries.create_index_facts_source()
        test_queries.create_index_facts_location()
        test_queries.create_index_facts_timestamp()
        test_queries.create_index_facts_source_subject()
        test_queries.create_index_facts_subject_predicate()
        test_queries.create_table_fact_tags()
        test_queries.create_index_fact_tags_tag()
        test_queries.create_table_fact_provenance()
        test_queries.create_fts_table()
        test_queries.create_trigger_facts_ai()
        test_queries.create_trigger_facts_ad()
        test_queries.create_trigger_facts_au()
        test_queries.create_view_valid_facts()
        test_queries.create_view_character_knowledge()
        test_queries.create_view_world_facts()
    except Exception as e:
        print(f"Schema init error: {e}")
    
    yield temp_db_path
    
    # Disconnect test database
    test_queries.disconnect()


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
