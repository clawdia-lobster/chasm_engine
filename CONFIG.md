# Chasm Engine Server Configuration

## Quick Start

1. Copy `server.toml` to your preferred location (or use it as-is)
2. Edit the `world` path to point to a valid directory
3. Create a world description file at `{world}.txt`
4. Run `chasm-server` to start the server

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `ws_host` | WebSocket server host | `0.0.0.0` |
| `ws_port` | WebSocket server port | `8765` |
| `world` | Path to world data directory | Required |
| `loglevel` | Logging level | `info` |
| `jwt_secret` | Secret for JWT tokens | Required (change!) |
| `motd` | Message of the day | Welcome message |

## World Setup

The `world` path points to a directory where Chasm Engine stores:
- `world.sqlite` - World state database
- `facts.sqlite` - Fact system database
- `quests.sqlite` - Quest system database
- `memory/` - Character memory files

A world description file must exist at `{world}.txt`. This file describes the
setting and style of the world. Example:

```
The humourous universe of the Hitchhiker's Guide to the Galaxy.
[style: Douglas Adams; conversational; game of the year; Infocom]
```

## Security

**Important:** Change `jwt_secret` to a unique, random string in production!
The default value is insecure and should only be used for development.
