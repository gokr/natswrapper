## NATS C Client wrapper using Futhark
## 
## This provides a complete wrapper around the official nats.c library
## including core NATS and JetStream/KV support.
##
## Installation:
## 1. Install nats.c: https://github.com/nats-io/nats.c
## 2. Install Futhark: nimble install futhark
## 3. Install libclang for your platform
##
## Usage:
##   import nats_wrapper
##   
##   var conn: ptr natsConnection
##   let status = natsConnection_ConnectTo(addr conn, "nats://localhost:4222")
##   if status == NATS_OK:
##     # Use connection
##     natsConnection_Destroy(conn)

import futhark

# Configure Futhark to find nats.h
when defined(linux):
  importc:
    sysPath "/usr/include"
    sysPath "/usr/local/include" 
    path "/usr/include/nats"
    path "/usr/local/include/nats"
    "nats.h"

when defined(macosx):
  importc:
    sysPath "/usr/local/include"
    sysPath "/opt/homebrew/include"
    path "/usr/local/include/nats"
    path "/opt/homebrew/include/nats"
    "nats.h"

when defined(windows):
  importc:
    sysPath "C:/Program Files/nats.c/include"
    path "C:/Program Files/nats.c/include"
    "nats.h"

# Link against the nats library
when defined(linux) or defined(macosx):
  {.passL: "-lnats".}
when defined(windows):
  {.passL: "nats.lib".}

# Export commonly used types and functions for easier access
# Everything from nats.h is now available via Futhark

# Helper procs for more idiomatic Nim usage
proc checkStatus*(status: natsStatus): bool {.inline.} =
  ## Check if a NATS status is OK
  return status == NATS_OK

proc getErrorString*(status: natsStatus): string =
  ## Get error string for a status code
  let cstr = natsStatus_GetText(status)
  if cstr != nil:
    result = $cstr
  else:
    result = "Unknown error"

# Convenience wrapper for connection
type
  NatsConnection* = object
    conn*: ptr natsConnection
    
proc connect*(url: string = "nats://localhost:4222"): NatsConnection =
  ## Connect to NATS server
  var conn: ptr natsConnection
  let status = natsConnection_ConnectTo(addr conn, url.cstring)
  if not checkStatus(status):
    raise newException(IOError, "Failed to connect: " & getErrorString(status))
  result.conn = conn

proc close*(nc: var NatsConnection) =
  ## Close connection
  if nc.conn != nil:
    natsConnection_Destroy(nc.conn)
    nc.conn = nil

proc publish*(nc: NatsConnection, subject: string, data: string) =
  ## Publish a message
  let status = natsConnection_PublishString(nc.conn, subject.cstring, data.cstring)
  if not checkStatus(status):
    raise newException(IOError, "Publish failed: " & getErrorString(status))

proc subscribe*(nc: NatsConnection, subject: string, 
                callback: proc(msg: ptr natsMsg) {.cdecl.}): ptr natsSubscription =
  ## Subscribe to a subject
  var sub: ptr natsSubscription
  let status = natsConnection_Subscribe(addr sub, nc.conn, subject.cstring, 
                                        cast[natsMsgHandler](callback), nil)
  if not checkStatus(status):
    raise newException(IOError, "Subscribe failed: " & getErrorString(status))
  return sub

# Example usage (commented out)
when isMainModule:
  # Initialize NATS library
  var status = nats_Open(-1)
  if not checkStatus(status):
    echo "Failed to initialize NATS"
    quit(1)
  
  try:
    # Connect to NATS
    var nc = connect()
    defer: nc.close()
    
    # Publish a message
    nc.publish("test.subject", "Hello NATS!")
    echo "Published message"
    
    # Subscribe example
    proc msgHandler(msg: ptr natsMsg) {.cdecl.} =
      let subject = natsMsg_GetSubject(msg)
      let data = natsMsg_GetData(msg)
      echo "Received: ", $subject, " -> ", $data
      natsMsg_Destroy(msg)
    
    let sub = nc.subscribe("test.>", msgHandler)
    
    # Wait a bit for messages
    nats_Sleep(1000)
    
    # Unsubscribe
    discard natsSubscription_Destroy(sub)
    
  finally:
    # Cleanup NATS library
    nats_Close()
