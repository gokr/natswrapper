## Presence tracking tests using NATS JetStream KV
##
## Run with: nim c -r tests/test_presence.nim
##
## Note: Requires a NATS server with JetStream enabled at localhost:4222

import ../src/natswrapper
import unittest
import times, os, strutils

type
  PresenceTracker = object
    nc: NatsConnection
    js: ptr jsCtx
    kv: ptr kvStore
    bucketName: string
    clientId: string
    ttl: int64

proc initPresenceTracker(url: string, bucketName: string,
                          clientId: string, ttlSeconds: int = 10): PresenceTracker =
  result.nc = connect(url)
  result.bucketName = bucketName
  result.clientId = clientId
  result.ttl = ttlSeconds.int64 * 1_000_000_000

  var js: ptr jsCtx
  var status = natsConnection_JetStream(addr js, result.nc.conn, nil)
  if not checkStatus(status):
    raise newException(IOError, "Failed to get JetStream context: " & getErrorString(status))
  result.js = js

  var kvCfg: kvConfig
  status = kvConfig_Init(addr kvCfg)
  if not checkStatus(status):
    raise newException(IOError, "Failed to initialize KV config: " & getErrorString(status))
  kvCfg.Bucket = bucketName.cstring
  kvCfg.TTL = result.ttl
  kvCfg.MaxValueSize = 256

  var kv: ptr kvStore
  status = js_CreateKeyValue(addr kv, js, addr kvCfg)
  if not checkStatus(status):
    status = js_KeyValue(addr kv, js, bucketName.cstring)
    if not checkStatus(status):
      raise newException(IOError, "Failed to create/get KV bucket: " & getErrorString(status))
  result.kv = kv

proc sendHeartbeat(pt: PresenceTracker) =
  let key = "presence." & pt.clientId
  let timestamp = $getTime().toUnix()

  var rev: uint64
  var status = kvStore_PutString(addr rev, pt.kv, key.cstring, timestamp.cstring)
  if not checkStatus(status):
    raise newException(IOError, "Failed to send heartbeat: " & getErrorString(status))

proc isPresent(pt: PresenceTracker, clientId: string): bool =
  let key = "presence." & clientId
  var entry: ptr kvEntry

  let status = kvStore_Get(addr entry, pt.kv, key.cstring)
  if status == NATS_OK:
    kvEntry_Destroy(entry)
    return true
  elif status == NATS_NOT_FOUND:
    return false
  else:
    raise newException(IOError, "Failed to check presence: " & getErrorString(status))

proc close(pt: var PresenceTracker) =
  if pt.kv != nil:
    kvStore_Destroy(pt.kv)
    pt.kv = nil
  if pt.js != nil:
    jsCtx_Destroy(pt.js)
    pt.js = nil
  pt.nc.close()

suite "Presence Tracking (requires NATS with JetStream)":
  test "initialize presence tracker":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var tracker = initPresenceTracker("nats://localhost:4222",
                                          "test_presence_init",
                                          "test_client_1",
                                          ttlSeconds = 5)
        defer: tracker.close()

        check tracker.nc.conn != nil
        check tracker.js != nil
        check tracker.kv != nil

      except IOError:
        skip()
      finally:
        nats_Close()
    else:
      skip()

  test "send heartbeat and check presence":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        let clientId = "test_client_2"
        var tracker = initPresenceTracker("nats://localhost:4222",
                                          "test_presence_heartbeat",
                                          clientId,
                                          ttlSeconds = 10)
        defer: tracker.close()

        # Initially should not be present
        # (or might be present from previous test run)

        # Send heartbeat
        tracker.sendHeartbeat()

        # Should now be present
        check tracker.isPresent(clientId)

      except IOError:
        skip()
      finally:
        nats_Close()
    else:
      skip()

  test "TTL expiration":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        let clientId = "test_client_ttl"
        var tracker = initPresenceTracker("nats://localhost:4222",
                                          "test_presence_ttl",
                                          clientId,
                                          ttlSeconds = 3)  # Short TTL for testing
        defer: tracker.close()

        # Send initial heartbeat
        tracker.sendHeartbeat()
        check tracker.isPresent(clientId)

        # Wait for TTL to expire
        sleep(4000)  # 4 seconds > 3 second TTL

        # Should no longer be present
        check not tracker.isPresent(clientId)

      except IOError:
        skip()
      finally:
        nats_Close()
    else:
      skip()

  test "heartbeat keeps presence alive":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        let clientId = "test_client_keepalive"
        var tracker = initPresenceTracker("nats://localhost:4222",
                                          "test_presence_keepalive",
                                          clientId,
                                          ttlSeconds = 5)
        defer: tracker.close()

        # Send heartbeats more frequently than TTL
        for i in 0..2:
          tracker.sendHeartbeat()
          sleep(2000)  # 2 seconds < 5 second TTL
          check tracker.isPresent(clientId)

      except IOError:
        skip()
      finally:
        nats_Close()
    else:
      skip()

  test "multiple clients presence":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        var tracker1 = initPresenceTracker("nats://localhost:4222",
                                           "test_presence_multi",
                                           "client_1",
                                           ttlSeconds = 10)
        defer: tracker1.close()

        var tracker2 = initPresenceTracker("nats://localhost:4222",
                                           "test_presence_multi",
                                           "client_2",
                                           ttlSeconds = 10)
        defer: tracker2.close()

        # Both send heartbeats
        tracker1.sendHeartbeat()
        tracker2.sendHeartbeat()

        # Both should be present
        check tracker1.isPresent("client_1")
        check tracker1.isPresent("client_2")
        check tracker2.isPresent("client_1")
        check tracker2.isPresent("client_2")

      except IOError:
        skip()
      finally:
        nats_Close()
    else:
      skip()

  test "resume presence after expiration":
    var status = nats_Open(-1)
    if checkStatus(status):
      try:
        let clientId = "test_client_resume"
        var tracker = initPresenceTracker("nats://localhost:4222",
                                          "test_presence_resume",
                                          clientId,
                                          ttlSeconds = 3)
        defer: tracker.close()

        # Send heartbeat
        tracker.sendHeartbeat()
        check tracker.isPresent(clientId)

        # Wait for expiration
        sleep(4000)
        check not tracker.isPresent(clientId)

        # Resume with new heartbeat
        tracker.sendHeartbeat()
        check tracker.isPresent(clientId)

      except IOError:
        skip()
      finally:
        nats_Close()
    else:
      skip()
