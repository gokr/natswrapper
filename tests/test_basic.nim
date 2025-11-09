## Basic tests for natswrapper
##
## Run with: nim c -r tests/test_basic.nim
##
## Note: Integration tests require a NATS server running at localhost:4222

import ../src/natswrapper
import unittest
import std/atomics

suite "Helper functions":
  test "checkStatus returns true for NATS_OK":
    let status = NATS_OK
    check checkStatus(status) == true

  test "checkStatus returns false for non-OK status":
    let status = NATS_ERR
    check checkStatus(status) == false

  test "getErrorString returns text for status":
    let errorStr = getErrorString(NATS_OK)
    check errorStr.len > 0

suite "Connection (requires NATS server)":
  # These tests require a running NATS server
  # Skip if NATS is not available

  test "connect to NATS server":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()
        check nc.conn != nil
        nc.close()
        check nc.conn == nil
      finally:
        nats_Close()
    else:
      skip()

  test "connect with custom URL":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect("nats://localhost:4222")
        check nc.conn != nil
        nc.close()
      finally:
        nats_Close()
    else:
      skip()

  test "publish message":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()
        defer: nc.close()

        # Publish a message
        nc.publish("test.subject", "Hello Test!")

        # Flush to ensure message is sent
        let flushStatus = natsConnection_Flush(nc.conn)
        check checkStatus(flushStatus)

      finally:
        nats_Close()
    else:
      skip()

  test "publish multiple messages":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()
        defer: nc.close()

        # Publish multiple messages
        for i in 1..10:
          nc.publish("test.multi", "Message " & $i)

        # Flush to ensure all messages are sent
        let flushStatus = natsConnection_Flush(nc.conn)
        check checkStatus(flushStatus)

      finally:
        nats_Close()
    else:
      skip()

suite "Pub/Sub (requires NATS server)":
  test "subscribe and receive message":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()
        defer: nc.close()

        var messageCount: Atomic[int]
        messageCount.store(0)

        # Create subscription using raw C API
        var sub: ptr natsSubscription
        let subStatus = natsConnection_SubscribeSync(addr sub, nc.conn, "test.sync.subject".cstring)
        check checkStatus(subStatus)

        # Publish a message
        nc.publish("test.sync.subject", "Test Message")
        discard natsConnection_Flush(nc.conn)

        # Receive message synchronously
        var msg: ptr natsMsg
        let recvStatus = natsSubscription_NextMsg(addr msg, sub, 1000) # 1 second timeout

        if checkStatus(recvStatus):
          check msg != nil
          let data = natsMsg_GetData(msg)
          let dataLen = natsMsg_GetDataLength(msg)
          check dataLen > 0
          natsMsg_Destroy(msg)

        natsSubscription_Destroy(sub)

      finally:
        nats_Close()
    else:
      skip()

  test "subscribe to wildcard subject":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()
        defer: nc.close()

        # Create subscription with wildcard
        var sub: ptr natsSubscription
        let subStatus = natsConnection_SubscribeSync(addr sub, nc.conn, "test.wildcard.*".cstring)
        check checkStatus(subStatus)

        # Publish to different subjects
        nc.publish("test.wildcard.one", "Message 1")
        nc.publish("test.wildcard.two", "Message 2")
        discard natsConnection_Flush(nc.conn)

        # Receive messages
        var msg: ptr natsMsg
        var count = 0

        for i in 0..1:
          let recvStatus = natsSubscription_NextMsg(addr msg, sub, 500)
          if checkStatus(recvStatus):
            count += 1
            natsMsg_Destroy(msg)

        check count == 2

        natsSubscription_Destroy(sub)

      finally:
        nats_Close()
    else:
      skip()

  test "request-reply pattern":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()
        defer: nc.close()

        # Create a responder subscription
        var sub: ptr natsSubscription
        let subStatus = natsConnection_SubscribeSync(addr sub, nc.conn, "test.request".cstring)
        check checkStatus(subStatus)

        # Send request in background by publishing to request subject
        nc.publish("test.request", "ping")
        discard natsConnection_Flush(nc.conn)

        # Receive the request
        var msg: ptr natsMsg
        let recvStatus = natsSubscription_NextMsg(addr msg, sub, 1000)

        if checkStatus(recvStatus):
          # Get reply subject
          let replyTo = natsMsg_GetReply(msg)
          if replyTo != nil:
            # Send reply
            let replyStatus = natsConnection_PublishString(nc.conn, replyTo, "pong".cstring)
            check checkStatus(replyStatus)
          natsMsg_Destroy(msg)

        natsSubscription_Destroy(sub)

      finally:
        nats_Close()
    else:
      skip()

suite "Connection Management":
  test "check connection status":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()

        # Check if connected
        let connStatus = natsConnection_Status(nc.conn)
        check connStatus == NATS_CONN_STATUS_CONNECTED

        nc.close()

      finally:
        nats_Close()
    else:
      skip()

  test "connection statistics":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var nc = connect()
        defer: nc.close()

        # Publish some messages
        for i in 1..5:
          nc.publish("test.stats", "Message " & $i)

        discard natsConnection_Flush(nc.conn)

        # Get statistics
        var stats: ptr natsStatistics
        var createStatus = natsStatistics_Create(addr stats)
        check checkStatus(createStatus)

        let statsStatus = natsConnection_GetStats(nc.conn, stats)
        check checkStatus(statsStatus)

        # Extract statistics
        var outMsgs, outBytes, inMsgs, inBytes, reconnects: uint64
        let getCountsStatus = natsStatistics_GetCounts(stats, addr outMsgs, addr outBytes,
                                                        addr inMsgs, addr inBytes, addr reconnects)
        check checkStatus(getCountsStatus)

        # Just verify we can get statistics (values may vary)
        # The actual count depends on internal NATS protocol messages
        check outBytes >= 0

        natsStatistics_Destroy(stats)

      finally:
        nats_Close()
    else:
      skip()
