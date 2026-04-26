#!/usr/bin/env python
"""End-to-end WebSocket integration test."""

import asyncio
import json
import sys
import os
from pathlib import Path

# Set config file location BEFORE importing chasm
os.chdir(str(Path(__file__).parent))

# Create a minimal client.toml to satisfy chasm/__init__.py
client_toml = Path(__file__).parent.parent / "chasm" / "client.toml"
if not client_toml.exists():
    client_toml.write_text('name = "Test"\npassphrase = "test"\nwebsocket_url = "ws://localhost:8765"\n')

sys.path.insert(0, str(Path(__file__).parent.parent / "repos" / "chasm"))
sys.path.insert(0, str(Path(__file__).parent.parent / "repos" / "chasm_engine"))


async def test_protocol():
    """Test WebSocket JSON-RPC protocol."""
    import websockets
    
    print("Testing WebSocket protocol...")
    
    # Start server
    from chasm.ws_server import serve_async
    server_task = asyncio.create_task(serve_async())
    await asyncio.sleep(1)
    
    try:
        async with websockets.connect("ws://localhost:8765") as ws:
            print("  ✓ Connected")
            
            # Test motd
            await ws.send(json.dumps({"jsonrpc": "2.0", "method": "motd", "id": "1"}))
            resp = json.loads(await ws.recv())
            assert "result" in resp, f"motd failed: {resp}"
            print("  ✓ motd")
            
            # Test status
            await ws.send(json.dumps({"jsonrpc": "2.0", "method": "status", "id": "2"}))
            resp = json.loads(await ws.recv())
            assert "result" in resp, f"status failed: {resp}"
            print("  ✓ status")
            
            # Test online
            await ws.send(json.dumps({"jsonrpc": "2.0", "method": "online", "id": "3"}))
            resp = json.loads(await ws.recv())
            assert "result" in resp, f"online failed: {resp}"
            print("  ✓ online")
            
            print("\nAll tests passed!")
            return True
    except Exception as e:
        print(f"  ✗ {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        server_task.cancel()
        try:
            await server_task
        except asyncio.CancelledError:
            pass


if __name__ == "__main__":
    sys.exit(0 if asyncio.run(test_protocol()) else 1)
