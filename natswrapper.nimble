# Package

version       = "0.1.0"
author        = "Göran Krampe"
description   = "NATS C Client wrapper using Futhark"
license       = "MIT"
srcDir        = "src"
skipDirs      = @["examples", "tests"]

# Dependencies

requires "nim >= 2.0.0"
requires "futhark >= 0.13.0"

# Tasks

task test, "Run all tests":
  exec "nim c -r tests/test_basic.nim"
  exec "nim c -r tests/test_presence.nim"

task examples, "Build and run all examples":
  echo "=== High-Level API Example ==="
  exec "nim c -r examples/highlevel_pubsub.nim"
  echo ""
  echo "=== Low-Level API Example ==="
  exec "nim c -r examples/simple_pubsub.nim"
  echo ""
  echo "=== Presence Tracking Example ==="
  exec "nim c -r examples/nats_presence_example.nim"
