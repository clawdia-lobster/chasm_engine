#!/usr/bin/env python
"""
End-to-end WebSocket integration test.
Tests the full server/client communication flow.
"""

import asyncio
import json
import sys
import os
import tempfile
import shutil
from pathlib import Path

# Set up paths
sys.path.insert(0, str(Path(__file__).parent.parent / "repos" / "chasm"))
sys.path.insert(0, str(Path(__file__).parent.parent / "repos" / "chasm_engine"))

# Set config file location
os.chdir(str(Path(__file__).parent))


async def test_websocket_protocol():
    """Test WebSocket JSON-RPC protocol."""
    import websockets
    from chasm_engine import log
    
    print("Testing WebSocket protocol...")
    
    # Start server in background
    from chasm.ws_server import serve_async
    server_task = asyncio.create_task(serve_async())
    
    # Wait for server to start
    await asyncio.sleep(1)
    
    try:
        # Connect as client
        async with websockets.connect("ws://localhost:8765") as ws:
            print("  ✓ Connected to server")
            
            # Test motd method
            request = {
                "jsonrpc": "2.0",
                "method": "motd",
                "id": "test-1"
            }
            await ws.send(json.dumps(request))
            response = json.loads(await ws.recv())
            
            if "result" in response:
                print("  ✓ motd method works")
            else:
                print(f"  ✗ motd failed: {response}")
                return False
            
            # Test status method
            request = {
                "jsonrpc": "2.0",
                "method": "status",
                "id": "test-2"
            }
            await ws.send(json.dumps(request))
            response = json.loads(await ws.recv())
            
            if "result" in response:
                print("  ✓ status method works")
            else:
                print(f"  ✗ status failed: {response}")
                return False
            
            # Test online method
            request = {
                "jsonrpc": "2.0",
                "method": "online",
                "id": "test-3"
            }
            await ws.send(json.dumps(request))
            response = json.loads(await ws.recv())
            
            if "result" in response:
                print("  ✓ online method works")
            else:
                print(f"  ✗ online failed: {response}")
                return False
            
            print("\nAll WebSocket protocol tests passed!")
            return True
            
    except Exception as e:
        print(f"  ✗ Error: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        # Cancel server
        server_task.cancel()
        try:
            await server_task
        except asyncio.CancelledError:
            pass


if __name__ == "__main__":
    try:
        result = asyncio.run(test_websocket_protocol())
        sys.exit(0 if result else 1)
    except KeyboardInterrupt:
        print("\nInterrupted")
        sys.exit(1)
