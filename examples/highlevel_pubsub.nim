## High-level Pub/Sub Example
##
## This demonstrates the idiomatic, high-level Nim API for NATS
## Compare this to simple_pubsub.nim to see the difference!

import ../src/nats
import os

proc main() =
  echo "=== High-Level NATS API Example ==="
  echo ""

  # Connect - clean and simple!
  echo "Connecting to NATS..."
  let client = newNatsClient()
  defer: client.close()
  echo "Connected!"
  echo ""

  # Subscribe with a clean callback - no pointers, no manual cleanup!
  echo "Setting up subscription to 'demo.>'..."
  var messageCount = 0

  client.subscribe("demo.>") do (subject: string, data: string):
    messageCount += 1
    echo "[", messageCount, "] Subject: ", subject
    echo "    Data: ", data
    echo ""

  echo "Subscribed!"
  echo ""

  # Publish - just strings, no .cstring needed!
  echo "Publishing messages..."
  client.publish("demo.hello", "Hello from Nim!")
  client.publish("demo.test", "Test message")
  client.publish("demo.foo.bar", "Nested subject")
  echo "Published 3 messages"
  echo ""

  # Give time for messages to arrive
  echo "Waiting for messages..."
  sleep(500)

  echo "Done! Received ", messageCount, " messages"
  echo ""

  # Demonstrate request/reply
  echo "=== Request/Reply Example ==="
  echo ""

  # Set up a responder
  echo "Setting up echo service on 'service.echo'..."
  client.subscribe("service.echo") do (subject: string, data: string):
    echo "Echo service received: ", data
    # In a real service, you'd use natsMsg_GetReply to send a response
    # The high-level API doesn't yet support replying, but it's on the roadmap

  echo ""
  echo "Note: Full request/reply requires server-side reply handling"
  echo "See the low-level API (natswrapper) for complete control"

when isMainModule:
  main()
