## Simple Pub/Sub Example
##
## This demonstrates basic NATS publish and subscribe functionality

import ../src/natswrapper

when isMainModule:
  # Initialize NATS library
  var status = nats_Open(-1)
  if not checkStatus(status):
    echo "Failed to initialize NATS"
    quit(1)

  try:
    # Connect to NATS server
    echo "Connecting to NATS server..."
    var nc = connect("nats://localhost:4222")
    defer: nc.close()

    echo "Connected!"
    echo ""

    # Create a synchronous subscription
    echo "Creating subscription to 'demo.>'..."
    var sub: ptr natsSubscription
    status = natsConnection_SubscribeSync(addr sub, nc.conn, "demo.>".cstring)
    if not checkStatus(status):
      echo "Failed to subscribe: ", getErrorString(status)
      quit(1)

    echo "Subscribed!"
    echo ""

    # Publish some messages
    echo "Publishing messages..."
    nc.publish("demo.hello", "Hello from Nim!")
    nc.publish("demo.test", "Test message")
    nc.publish("demo.foo.bar", "Nested subject")

    # Flush to ensure messages are sent
    discard natsConnection_Flush(nc.conn)
    echo ""

    # Receive and display messages
    echo "Receiving messages (timeout: 2 seconds)..."
    echo ""

    var count = 0
    while true:
      var msg: ptr natsMsg
      status = natsSubscription_NextMsg(addr msg, sub, 500) # 500ms timeout

      if status == NATS_TIMEOUT:
        break

      if not checkStatus(status):
        echo "Error receiving message: ", getErrorString(status)
        break

      # Get message details
      let subject = natsMsg_GetSubject(msg)
      let data = natsMsg_GetData(msg)
      let dataLen = natsMsg_GetDataLength(msg)

      # Convert data to string
      var msgText = ""
      if data != nil and dataLen > 0:
        var buffer = newString(dataLen)
        copyMem(addr buffer[0], data, dataLen)
        msgText = buffer

      count += 1
      echo "[", count, "] Subject: ", $subject
      echo "    Data: ", msgText
      echo ""

      natsMsg_Destroy(msg)

    echo "Received ", count, " messages"
    echo ""

    # Cleanup subscription
    natsSubscription_Destroy(sub)

    echo "Done!"

  finally:
    # Cleanup NATS library
    nats_Close()
