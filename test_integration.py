#!/usr/bin/env python
"""Simple WebSocket integration test."""

import asyncio
import sys
import os

# Add paths
sys.path.insert(0, "/home/node/.openclaw/workspace-nereus/repos/chasm")
sys.path.insert(0, "/home/node/.openclaw/workspace-nereus/repos/chasm_engine")

# Set config file location
os.chdir("/home/node/.openclaw/workspace-nereus/repos/chasm_engine")

async def test_imports():
    """Test that modules can be imported."""
    print("Testing imports...")
    
    import chasm_engine
    print("  ✓ chasm_engine")
    
    import chasm_engine.engine
    print("  ✓ chasm_engine.engine")
    
    import chasm.ws_server
    print("  ✓ chasm.ws_server")
    
    import chasm.client
    print("  ✓ chasm.client")
    
    print("\nAll imports successful!")
    return True

if __name__ == "__main__":
    try:
        result = asyncio.run(test_imports())
        sys.exit(0 if result else 1)
    except Exception as e:
        print(f"\n✗ Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
