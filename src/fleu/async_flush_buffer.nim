import ./stringresize, lib/asyncwrapper
import std/unicode # just to expose API otherwise not used

type
  AsyncBufferConsumer* = proc (x: openArray[char]): Future[int]
  AsyncFlushBuffer* = object
    data*: string
    consumer*: AsyncBufferConsumer
      ## returns number of characters consumed
      ## set to nil after returning negative
    freeBefore*: int
      ## position before which we can cull the buffer
    flushPos*: int
      ## position before which the buffer has been flushed

{.push checks: off, stacktrace: off.}

proc initAsyncFlushBuffer*(capacity = 16): AsyncFlushBuffer {.inline.} =
  result = AsyncFlushBuffer(data: newStringOfCap(capacity), consumer: nil)

proc initAsyncFlushBuffer*(consumer: AsyncBufferConsumer, capacity = 16): AsyncFlushBuffer {.inline.} =
  result = AsyncFlushBuffer(data: newStringOfCap(capacity), consumer: consumer)

when declared(asyncstreams):
  proc initAsyncFlushBuffer*(stream: FutureStream[string], capacity = 16): AsyncFlushBuffer {.inline.} =
    let consumer = proc (x: openArray[char]): Future[int] {.async.} =
      var s = newString(x.len)
      when nimvm:
        for i in 0 ..< x.len:
          s[i] = x[i]
      else:
        when defined(js) or defined(nimscript):
          for i in 0 ..< x.len:
            s[i] = x[i]
        else:
          copyMem(addr s[0], addr x[0], x.len)
      await stream.write(s)
      result = x.len
    result = initAsyncFlushBuffer(consumer, capacity)
  proc initAsyncFlushBuffer*(stream: FutureStream[char], capacity = 16): AsyncFlushBuffer {.inline.} =
    let consumer = proc (x: openArray[char]): Future[int] {.async.} =
      for c in x:
        await stream.write(c)
      result = x.len
    result = initAsyncFlushBuffer(consumer, capacity)
  proc initAsyncFlushBuffer*(stream: FutureStream[byte], capacity = 16): AsyncFlushBuffer {.inline.} =
    let consumer = proc (x: openArray[char]): Future[int] {.async.} =
      for c in x:
        await stream.write(c.byte)
      result = x.len
    result = initAsyncFlushBuffer(consumer, capacity)

when declared(AsyncFile):
  proc initAsyncFlushBuffer*(file: AsyncFile, capacity = 16): AsyncFlushBuffer {.inline.} =
    ## `file` has to last as long as the flush
    let consumer = proc (x: openArray[char]): Future[int] {.async.} =
      await file.writeBuffer(addr x[0], x.len)
      result = x.len
    result = initAsyncFlushBuffer(consumer, capacity)

proc add*(buffer: var AsyncFlushBuffer, c: char) {.inline.} =
  let moved = smartResizeAdd(buffer.data, c, buffer.freeBefore)
  if moved:
    buffer.flushPos -= buffer.freeBefore
    buffer.freeBefore = 0

proc add*(buffer: var AsyncFlushBuffer, s: string) {.inline.} =
  let moved = smartResizeAdd(buffer.data, s, buffer.freeBefore)
  if moved:
    buffer.flushPos -= buffer.freeBefore
    buffer.freeBefore = 0

proc add*(buffer: var AsyncFlushBuffer, s: openArray[char]) {.inline.} =
  let moved = smartResizeAdd(buffer.data, s, buffer.freeBefore)
  if moved:
    buffer.flushPos -= buffer.freeBefore
    buffer.freeBefore = 0

proc add*(buffer: var AsyncFlushBuffer, rune: Rune) {.inline.} =
  var bytes = newStringOfCap(size(rune)) # could be a constant array but fastToUTF8Copy does not allow it
  fastToUTF8Copy(rune, bytes, 0, doInc = false)
  let moved = smartResizeAdd(buffer.data, bytes, buffer.freeBefore)
  if moved:
    buffer.flushPos -= buffer.freeBefore
    buffer.freeBefore = 0

proc callConsumer*(buffer: var AsyncFlushBuffer) {.async.} =
  ## for internal use, only called if buffer consumer is known not to be nil
  # probably better not to inline
  let len = buffer.data.len
  if buffer.flushPos < len:
    let consumed = await buffer.consumer(buffer.data.toOpenArray(buffer.flushPos, len - 1))
    if consumed < 0:
      buffer.consumer = nil
      return
    buffer.flushPos += consumed

proc consume*(buffer: var AsyncFlushBuffer) {.async.} =
  # is there a way to inline this
  if not buffer.consumer.isNil:
    await callConsumer(buffer)

proc callConsumerFull*(buffer: var AsyncFlushBuffer) {.async.} =
  ## for internal use, only called if buffer consumer is known not to be nil
  # probably better not to inline
  let len = buffer.data.len
  while buffer.flushPos < len:
    let consumed = await buffer.consumer(buffer.data.toOpenArray(buffer.flushPos, len - 1))
    if consumed < 0:
      buffer.consumer = nil
      return
    buffer.flushPos += consumed

proc consumeFull*(buffer: var AsyncFlushBuffer) {.async.} =
  # is there a way to inline this
  if not buffer.consumer.isNil:
    await callConsumerFull(buffer)

proc callConsumerEnd*(buffer: var AsyncFlushBuffer) {.inline.} =
  ## for internal use, only called if buffer consumer is known not to be nil
  asyncCheck buffer.consumer([])
  buffer.consumer = nil

proc endFlush*(buffer: var AsyncFlushBuffer) {.async.} =
  ## signals to consumer the end of flushing, leaves remaining buffer
  # is there a way to inline this
  if not buffer.consumer.isNil:
    callConsumerEnd(buffer)

proc callConsumerFinish*(buffer: var AsyncFlushBuffer) {.async.} =
  ## for internal use, only called if buffer consumer is known not to be nil
  # is there a way to inline this
  await buffer.callConsumerFull()
  if not buffer.consumer.isNil:
    callConsumerEnd(buffer)

proc finishFlush*(buffer: var AsyncFlushBuffer) {.async.} =
  ## fully flushes buffer and signals end of flushing to consumer if consumer still exists
  # is there a way to inline this
  if not buffer.consumer.isNil:
    await callConsumerFinish(buffer)

{.pop.}
