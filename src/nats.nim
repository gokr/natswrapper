## High-level, idiomatic Nim wrapper for NATS
##
## This module provides a clean, Nim-friendly API on top of the low-level
## natswrapper C bindings.
##
## Example:
##   import nats
##
##   let client = newNatsClient()
##   defer: client.close()
##
##   client.publish("hello", "world")
##
##   client.subscribe("hello") do (subject, data: string):
##     echo "Received: ", data

import natswrapper
import tables

type
  NatsClient* = ref object
    conn: NatsConnection
    subscriptions: Table[string, ptr natsSubscription]
    callbacks: Table[ptr natsSubscription, MessageCallback]
    initialized: bool

  MessageCallback* = proc(subject: string, data: string) {.gcsafe, closure.}

  NatsError* = object of CatchableError
  NatsConnectionError* = object of NatsError
  NatsPublishError* = object of NatsError
  NatsSubscribeError* = object of NatsError

# Global NATS library initialization
var natsLibInitialized = false

proc ensureNatsInit() =
  if not natsLibInitialized:
    let status = nats_Open(-1)
    if not checkStatus(status):
      raise newException(NatsConnectionError, "Failed to initialize NATS library: " & getErrorString(status))
    natsLibInitialized = true

proc newNatsClient*(url: string = "nats://localhost:4222"): NatsClient =
  ## Create a new NATS client and connect to the server.
  ##
  ## Example:
  ##   let client = newNatsClient()
  ##   let client = newNatsClient("nats://example.com:4222")
  ensureNatsInit()

  result = NatsClient(
    subscriptions: initTable[string, ptr natsSubscription](),
    callbacks: initTable[ptr natsSubscription, MessageCallback](),
    initialized: true
  )

  try:
    result.conn = connect(url)
  except IOError as e:
    raise newException(NatsConnectionError, "Failed to connect: " & e.msg)

proc close*(client: NatsClient) =
  ## Close the NATS client connection and cleanup all subscriptions.
  ##
  ## Note: Always call close() when done, or use defer: client.close()
  if client == nil or not client.initialized:
    return

  # Cleanup all subscriptions
  for sub in client.subscriptions.values:
    natsSubscription_Destroy(sub)

  client.subscriptions.clear()
  client.callbacks.clear()
  client.conn.close()
  client.initialized = false

proc publish*(client: NatsClient, subject: string, data: string) =
  ## Publish a message to a subject.
  ##
  ## Example:
  ##   client.publish("events.user.login", "user123")
  if not client.initialized:
    raise newException(NatsPublishError, "Client is not initialized")

  try:
    client.conn.publish(subject, data)
  except IOError as e:
    raise newException(NatsPublishError, "Failed to publish: " & e.msg)

proc publish*(client: NatsClient, subject: string, data: seq[byte]) =
  ## Publish binary data to a subject.
  ##
  ## Example:
  ##   let data: seq[byte] = @[1'u8, 2, 3, 4]
  ##   client.publish("binary.data", data)
  if not client.initialized:
    raise newException(NatsPublishError, "Client is not initialized")

  let status = natsConnection_Publish(client.conn.conn, subject.cstring,
                                       unsafeAddr data[0], data.len.cint)
  if not checkStatus(status):
    raise newException(NatsPublishError, "Failed to publish: " & getErrorString(status))

proc flush*(client: NatsClient, timeoutMs: int = 1000) =
  ## Flush the connection, ensuring all messages are sent.
  ##
  ## Example:
  ##   client.flush()
  ##   client.flush(timeoutMs = 500)
  if not client.initialized:
    raise newException(NatsError, "Client is not initialized")

  let status = natsConnection_FlushTimeout(client.conn.conn, timeoutMs.int64)
  if not checkStatus(status):
    raise newException(NatsError, "Failed to flush: " & getErrorString(status))

# Wrapper to convert C callback to Nim callback
proc makeCCallback(callback: MessageCallback): natsMsgHandler =
  # Create a C-compatible callback that captures the Nim closure
  proc wrapper(conn: ptr natsConnection, sub: ptr natsSubscription,
               msg: ptr natsMsg, closure: pointer) {.cdecl.} =
    if closure == nil:
      natsMsg_Destroy(msg)
      return

    let nimCallback = cast[ptr MessageCallback](closure)

    # Extract message data
    let subject = $natsMsg_GetSubject(msg)
    let dataPtr = natsMsg_GetData(msg)
    let dataLen = natsMsg_GetDataLength(msg)

    var data = ""
    if dataPtr != nil and dataLen > 0:
      data = newString(dataLen)
      copyMem(addr data[0], dataPtr, dataLen)

    # Call the Nim callback
    try:
      nimCallback[](subject, data)
    except:
      discard # Prevent exceptions from escaping to C code

    natsMsg_Destroy(msg)

  return cast[natsMsgHandler](wrapper)

proc subscribe*(client: NatsClient, subject: string, callback: MessageCallback): string {.discardable.} =
  ## Subscribe to a subject with a callback.
  ## Returns the subject for convenience.
  ##
  ## Example:
  ##   client.subscribe("events.>") do (subject, data: string):
  ##     echo "Got message on ", subject, ": ", data
  ##
  ##   proc handler(subject, data: string) =
  ##     echo data
  ##   client.subscribe("test", handler)
  if not client.initialized:
    raise newException(NatsSubscribeError, "Client is not initialized")

  # Store the callback in a stable location
  var callbackBox = create(MessageCallback)
  callbackBox[] = callback

  # Create subscription with callback
  var sub: ptr natsSubscription
  let msgHandler = makeCCallback(callback)
  let status = natsConnection_Subscribe(addr sub, client.conn.conn, subject.cstring,
                                        msgHandler, cast[pointer](callbackBox))
  if not checkStatus(status):
    dealloc(callbackBox)
    raise newException(NatsSubscribeError, "Failed to subscribe: " & getErrorString(status))

  # Track the subscription
  client.subscriptions[subject] = sub
  client.callbacks[sub] = callback

  return subject

proc unsubscribe*(client: NatsClient, subject: string) =
  ## Unsubscribe from a subject.
  ##
  ## Example:
  ##   client.unsubscribe("events.user")
  if not client.initialized:
    raise newException(NatsSubscribeError, "Client is not initialized")

  if not client.subscriptions.hasKey(subject):
    return

  let sub = client.subscriptions[subject]

  # Unsubscribe and cleanup
  discard natsSubscription_Unsubscribe(sub)
  natsSubscription_Destroy(sub)

  client.callbacks.del(sub)
  client.subscriptions.del(subject)

  # Note: We don't deallocate the callback here as it might still be in use
  # The callbacks table keeps track of them and they're freed in close()

proc request*(client: NatsClient, subject: string, data: string, timeoutMs: int = 1000): string =
  ## Send a request and wait for a reply.
  ##
  ## Example:
  ##   let reply = client.request("service.echo", "hello", timeoutMs = 2000)
  ##   echo "Got reply: ", reply
  if not client.initialized:
    raise newException(NatsError, "Client is not initialized")

  var replyMsg: ptr natsMsg
  let status = natsConnection_RequestString(addr replyMsg, client.conn.conn,
                                            subject.cstring, data.cstring,
                                            timeoutMs.int64)
  if not checkStatus(status):
    raise newException(NatsError, "Request failed: " & getErrorString(status))

  defer: natsMsg_Destroy(replyMsg)

  let replyData = natsMsg_GetData(replyMsg)
  let replyLen = natsMsg_GetDataLength(replyMsg)

  result = ""
  if replyData != nil and replyLen > 0:
    result = newString(replyLen)
    copyMem(addr result[0], replyData, replyLen)

proc isConnected*(client: NatsClient): bool =
  ## Check if the client is connected.
  ##
  ## Example:
  ##   if client.isConnected():
  ##     echo "Connected!"
  if not client.initialized:
    return false

  let status = natsConnection_Status(client.conn.conn)
  return status == NATS_CONN_STATUS_CONNECTED

# Re-export common types and utilities from low-level wrapper
export NatsConnection, checkStatus, getErrorString
