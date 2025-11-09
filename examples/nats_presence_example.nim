## Example: Using NATS JetStream and KV for presence tracking
##
## This demonstrates how to use the KV store for heartbeat-based presence

import ../src/natswrapper
import times, os, strutils

type
  PresenceTracker* = object
    nc: NatsConnection
    js: ptr jsCtx
    kv: ptr kvStore
    bucketName: string
    clientId: string
    ttl: int64  # TTL in nanoseconds

proc initPresenceTracker*(url: string, bucketName: string, 
                          clientId: string, ttlSeconds: int = 10): PresenceTracker =
  ## Initialize a presence tracker with KV store
  
  # Connect to NATS
  result.nc = connect(url)
  result.bucketName = bucketName
  result.clientId = clientId
  result.ttl = ttlSeconds.int64 * 1_000_000_000  # Convert to nanoseconds
  
  # Get JetStream context
  var js: ptr jsCtx
  var status = natsConnection_JetStream(addr js, result.nc.conn, nil)
  if not checkStatus(status):
    raise newException(IOError, "Failed to get JetStream context: " & getErrorString(status))
  result.js = js
  
  # Create or get KV bucket with TTL
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
    # Try to get existing bucket
    status = js_KeyValue(addr kv, js, bucketName.cstring)
    if not checkStatus(status):
      raise newException(IOError, "Failed to create/get KV bucket: " & getErrorString(status))
  result.kv = kv

proc sendHeartbeat*(pt: PresenceTracker) =
  ## Send a heartbeat (update presence key with TTL)
  let key = "presence." & pt.clientId
  let timestamp = $getTime().toUnix()

  var rev: uint64
  var status = kvStore_PutString(addr rev, pt.kv, key.cstring, timestamp.cstring)
  if not checkStatus(status):
    raise newException(IOError, "Failed to send heartbeat: " & getErrorString(status))

proc isPresent*(pt: PresenceTracker, clientId: string): bool =
  ## Check if a client is present (key exists in KV)
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

proc listPresent*(pt: PresenceTracker): seq[string] =
  ## List all currently present clients
  result = @[]
  
  var watcher: ptr kvWatcher
  var status = kvStore_WatchAll(addr watcher, pt.kv, nil)
  if not checkStatus(status):
    raise newException(IOError, "Failed to create watcher: " & getErrorString(status))
  
  # Get initial state (synchronous read)
  # Note: This is simplified - in production you'd want proper async handling
  var entry: ptr kvEntry
  while true:
    status = kvWatcher_Next(addr entry, watcher, 100)  # 100ms timeout
    if status == NATS_TIMEOUT:
      break
    if not checkStatus(status):
      continue
    
    let key = $kvEntry_Key(entry)
    if key.startsWith("presence."):
      result.add(key[9..^1])  # Strip "presence." prefix
    
    kvEntry_Destroy(entry)
  
  kvWatcher_Destroy(watcher)

proc close*(pt: var PresenceTracker) =
  ## Cleanup presence tracker
  if pt.kv != nil:
    kvStore_Destroy(pt.kv)
    pt.kv = nil
  if pt.js != nil:
    jsCtx_Destroy(pt.js)
    pt.js = nil
  pt.nc.close()

# Example usage for Niffler
when isMainModule:
  # Initialize NATS
  var status = nats_Open(-1)
  if not checkStatus(status):
    echo "Failed to initialize NATS"
    quit(1)
  
  try:
    # Create presence tracker for this process
    let processId = "niffler_" & $getCurrentProcessId()
    var tracker = initPresenceTracker("nats://localhost:4222",
                                      "niffler_presence",
                                      processId,
                                      ttlSeconds = 10)
    defer: tracker.close()
    
    echo "Started presence tracking for: ", processId
    
    # Heartbeat loop - demonstrate active presence
    echo "\n=== Phase 1: Active heartbeats ==="
    for i in 0..5:  # Run for ~30 seconds
      # Send heartbeat
      tracker.sendHeartbeat()
      echo "Sent heartbeat #", i+1

      # List all present processes
      let present = tracker.listPresent()
      echo "Currently present processes: ", present

      # Sleep for a bit (less than TTL)
      sleep(5000)  # 5 seconds

    # Demonstrate TTL expiration by stopping heartbeats
    echo "\n=== Phase 2: Demonstrating TTL expiration ==="
    echo "Stopping heartbeats. TTL is 10 seconds, so presence should expire..."
    echo "Process ", processId, " is currently present: ", tracker.isPresent(processId)

    # Wait longer than TTL
    for i in 0..2:
      sleep(5000)
      let stillPresent = tracker.isPresent(processId)
      echo "After ", (i+1)*5, " seconds without heartbeat - still present: ", stillPresent
      if not stillPresent:
        echo "SUCCESS: Presence expired due to TTL!"
        break

    echo "\n=== Phase 3: Resuming heartbeats ==="
    for i in 0..2:
      tracker.sendHeartbeat()
      echo "Sent heartbeat #", i+1
      echo "Process is present again: ", tracker.isPresent(processId)
      sleep(3000)

    echo "\nPresence test completed"
    
  finally:
    nats_Close()
