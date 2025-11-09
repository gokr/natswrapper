# natswrapper - NATS Client Library for Nim

A complete Nim wrapper for the official NATS C client library using Futhark for automatic binding generation.

## Features

- **Core NATS**: Pub/sub, request/reply, queue groups
- **JetStream**: Streams, consumers, persistence
- **KV Store**: Key-value storage with TTL (perfect for presence tracking)
- **Object Store**: Object storage capabilities
- **Full API**: All nats.c functionality available via Futhark bindings
- **Tests**: Test covering major features

## Installation

### 1. Install NATS C library

**Ubuntu/Debian:**
```bash
sudo apt-get install libnats-dev
```

**macOS:**
```bash
brew install nats-c
```

**Windows:**
Download prebuilt binaries from https://github.com/nats-io/nats.c/releases

### 2. Install this package

```bash
nimble install
```

## Quick Start

This package provides **two APIs**:

1. **High-Level API** (`import nats`) - Idiomatic Nim, no manual memory management
2. **Low-Level API** (`import natswrapper`) - Thin C wrapper, full control

### High-Level API (Recommended)

Clean, idiomatic Nim - no pointers, no `.cstring`, automatic cleanup:

```nim
import nats

let client = newNatsClient()
defer: client.close()

# Publish - just strings!
client.publish("hello", "world")

# Subscribe with clean callbacks
client.subscribe("hello") do (subject, data: string):
  echo "Received: ", data

# Request/reply
let reply = client.request("service.echo", "ping", timeoutMs = 1000)
```

### Low-Level API (Full Control)

Direct access to the C library for advanced use cases:

```nim
import natswrapper

discard nats_Open(-1)
defer: nats_Close()

var nc = connect("nats://localhost:4222")
defer: nc.close()

nc.publish("hello", "world")
```

### Presence Tracking with JetStream KV

The package includes a complete presence tracking example using NATS JetStream KV store with TTL:

```bash
# Run the example (requires NATS server with JetStream enabled)
nimble examples
```

See `examples/nats_presence_example.nim` for a complete implementation showing:
- Heartbeat-based presence tracking
- Automatic TTL expiration
- Multi-client presence detection

## Running Tests

```bash
# Run all tests
nimble test
```

**Note:** Tests require a NATS server running at `localhost:4222`. For presence tests, JetStream must be enabled:
```bash
nats-server -js
```

## Package Structure

```
natswrapper/
├── src/
│   ├── nats.nim           # High-level, idiomatic Nim API
│   └── natswrapper.nim    # Low-level C wrapper (Futhark-generated)
├── examples/
│   ├── highlevel_pubsub.nim    # High-level API example
│   ├── simple_pubsub.nim       # Low-level API example
│   └── nats_presence_example.nim  # JetStream KV presence tracking
├── tests/
│   ├── test_basic.nim          # Core NATS tests
│   └── test_presence.nim       # Presence tracking tests
└── natswrapper.nimble
```

## Which API Should I Use?

- **Use High-Level API (`nats`)** if you want:
  - Clean, idiomatic Nim code
  - No manual memory management
  - Simple pub/sub and request/reply
  - Less boilerplate

- **Use Low-Level API (`natswrapper`)** if you need:
  - Advanced NATS features (JetStream, KV, streams)
  - Fine-grained control
  - Custom error handling
  - Performance-critical code

## Usage Examples

### Synchronous Subscription

```nim
import natswrapper

discard nats_Open(-1)

var nc = connect()
defer: nc.close()

# Subscribe synchronously
var sub: ptr natsSubscription
discard natsConnection_SubscribeSync(addr sub, nc.conn, "test.subject".cstring)

# Publish a message
nc.publish("test.subject", "Hello!")

# Receive the message
var msg: ptr natsMsg
let status = natsSubscription_NextMsg(addr msg, sub, 1000) # 1 second timeout
if checkStatus(status):
  let data = natsMsg_GetData(msg)
  echo "Received: ", $data
  natsMsg_Destroy(msg)

natsSubscription_Destroy(sub)
nats_Close()
```

### Wildcard Subscriptions

```nim
# Subscribe to all subjects matching pattern
var sub: ptr natsSubscription
discard natsConnection_SubscribeSync(addr sub, nc.conn, "events.*".cstring)

# Receives messages from events.user, events.system, etc.
```

### Request-Reply Pattern

```nim
# Publish with reply subject
var msg: ptr natsMsg
let status = natsConnection_Request(addr msg, nc.conn,
                                     "service.request".cstring,
                                     "data".cstring, 4, 1000)
if checkStatus(status):
  echo "Reply: ", $natsMsg_GetData(msg)
  natsMsg_Destroy(msg)
```

## Presence Tracking Architecture

For multi-process coordination, use the KV store pattern:

```nim
# Each process:
1. Creates a PresenceTracker with unique process ID
2. Sends heartbeats every 5 seconds
3. KV entries have 10-15 second TTL
4. If process crashes, entry expires automatically
5. Other processes can query who's alive via isPresent()/listPresent()
```

## How Futhark Works

This wrapper uses **Futhark** to automatically generate Nim bindings from the NATS C library headers **at compile time**. Here's what happens when you compile:

1. **Header Discovery**: Futhark locates the NATS C headers installed on your system (`/usr/include/nats/nats.h` on Linux)
2. **Parse with libclang**: Uses libclang to parse the C headers and understand the full API
3. **Generate Nim Code**: Creates complete Nim bindings (types, functions, enums, macros)
4. **Cache Results**: Caches the generated bindings for faster subsequent builds

**Key Point**: The bindings match **your installed version** of libnats. If you have libnats 3.8.0 installed, you get bindings for 3.8.0. Upgrade to 3.9.0, and Futhark automatically adapts.

### Force Regeneration

If you update your NATS library, you may want to force Futhark to regenerate bindings:

```bash
# Clear Futhark cache and rebuild
nim c -r -d:futharkRebuild src/natswrapper.nim
```

Or manually clear the cache:
```bash
rm -rf ~/.cache/nim/*/futhark_*.nim
```

## Requirements

- Nim >= 2.0.0
- Futhark >= 0.13.0
- libnats (NATS C client library)
- libclang (for Futhark)
- NATS server (for testing/runtime)

## Running a NATS Server

### Basic server
```bash
nats-server
```

### With JetStream (required for KV/presence)
```bash
nats-server -js
```

### Using Docker
```bash
docker run -p 4222:4222 nats:latest -js
```

## Documentation

- [NATS C API docs](https://nats-io.github.io/nats.c/)
- [Futhark docs](https://github.com/PMunch/futhark)
- [NATS concepts](https://docs.nats.io/)
