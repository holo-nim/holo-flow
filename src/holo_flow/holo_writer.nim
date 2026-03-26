import ./stringresize
import std/[streams, unicode] # just to expose API otherwise not used

type
  BufferConsumer* = proc (x: openArray[char]): int
    ## returns number of characters consumed
    ## set to nil after returning negative
  HoloWriter* = object
    buffer*: string
    bufferConsumer*: BufferConsumer
    freeBefore*: int
    flushPos*: int
    flushLocks*: int

{.push checks: off, stacktrace: off.}

proc initHoloWriter*(): HoloWriter {.inline.} =
  result = HoloWriter()

proc lockFlush*(writer: var HoloWriter) {.inline.} =
  inc writer.flushLocks

proc unlockFlush*(writer: var HoloWriter) {.inline.} =
  assert writer.flushLocks > 0, "unpaired flush unlock"
  dec writer.flushLocks

template startWriteImpl() =
  writer.flushLocks = 0
  writer.flushPos = 0
  writer.freeBefore = 0

proc startWrite*(writer: var HoloWriter, bufferCapacity = 16) {.inline.} =
  writer.buffer = newStringOfCap(bufferCapacity)
  writer.bufferConsumer = nil
  startWriteImpl()

proc startWrite*(writer: var HoloWriter, consumer: BufferConsumer, bufferCapacity = 16) {.inline.} =
  writer.buffer = newStringOfCap(bufferCapacity)
  writer.bufferConsumer = consumer
  startWriteImpl()

proc startWrite*(writer: var HoloWriter, stream: Stream, bufferCapacity = 16) {.inline.} =
  let consumer = proc (x: openArray[char]): int =
    when defined(js) or defined(nimscript):
      var s = newString(x.len)
      for i in 0 ..< x.len:
        s[i] = x[i]
      stream.write(s)
    else:
      stream.write(x)
    result = x.len
  writer.startWrite(consumer, bufferCapacity)

when declared(File):
  proc startWrite*(writer: var HoloWriter, file: File, bufferCapacity = 16) {.inline.} =
    ## `file` has to last as long as the writer
    let consumer = proc (x: openArray[char]): int =
      result = file.writeChars(x, 0, x.len)
    writer.startWrite(consumer, bufferCapacity)

proc addToBuffer*(writer: var HoloWriter, c: char) {.inline.} =
  let moved = smartResizeAdd(writer.buffer, c, writer.freeBefore)
  if moved:
    writer.flushPos -= writer.freeBefore
    writer.freeBefore = 0

proc addToBuffer*(writer: var HoloWriter, s: string) {.inline.} =
  let moved = smartResizeAdd(writer.buffer, s, writer.freeBefore)
  if moved:
    writer.flushPos -= writer.freeBefore
    writer.freeBefore = 0

proc addToBuffer*(writer: var HoloWriter, s: openArray[char]) {.inline.} =
  let moved = smartResizeAdd(writer.buffer, s, writer.freeBefore)
  if moved:
    writer.flushPos -= writer.freeBefore
    writer.freeBefore = 0

proc addToBuffer*(writer: var HoloWriter, rune: Rune) {.inline.} =
  var bytes = newStringOfCap(size(rune)) # could be a constant array but fastToUTF8Copy does not allow it
  fastToUTF8Copy(rune, bytes, 0, doInc = false)
  let moved = smartResizeAdd(writer.buffer, bytes, writer.freeBefore)
  if moved:
    writer.flushPos -= writer.freeBefore
    writer.freeBefore = 0

proc consumeBuffer*(writer: var HoloWriter) {.inline.} =
  if not writer.bufferConsumer.isNil:
    let len = writer.buffer.len
    if writer.flushPos < len:
      let consumed = writer.bufferConsumer(writer.buffer.toOpenArray(writer.flushPos, len - 1))
      if consumed < 0:
        writer.bufferConsumer = nil
        return
      writer.flushPos += consumed
      if writer.flushLocks == 0: writer.freeBefore = writer.flushPos

proc consumeBufferFull*(writer: var HoloWriter) {.inline.} =
  if not writer.bufferConsumer.isNil:
    let len = writer.buffer.len
    while writer.flushPos < len:
      let consumed = writer.bufferConsumer(writer.buffer.toOpenArray(writer.flushPos, len - 1))
      if consumed < 0:
        writer.bufferConsumer = nil
        return
      writer.flushPos += consumed
    if writer.flushLocks == 0: writer.freeBefore = writer.flushPos

proc write*(writer: var HoloWriter, c: char) {.inline.} =
  writer.addToBuffer(c)
  writer.consumeBuffer()

proc write*(writer: var HoloWriter, c: Rune) {.inline.} =
  writer.addToBuffer(c)
  writer.consumeBuffer()

proc write*(writer: var HoloWriter, s: string) {.inline.} =
  writer.addToBuffer(s)
  writer.consumeBuffer()

proc write*(writer: var HoloWriter, s: openArray[char]) {.inline.} =
  writer.addToBuffer(s)
  writer.consumeBuffer()

proc finishWrite*(writer: var HoloWriter): string {.inline.} =
  ## returns leftover buffer
  if false: assert writer.flushLocks == 0, "unpaired flush lock"
  if not writer.bufferConsumer.isNil:
    writer.consumeBufferFull()
    if not writer.bufferConsumer.isNil:
      discard writer.bufferConsumer([])
      writer.bufferConsumer = nil
  if writer.flushPos == 0:
    result = move writer.buffer
  elif writer.flushPos < writer.buffer.len:
    result = writer.buffer[writer.flushPos ..< writer.buffer.len]
  else:
    result = ""

{.pop.}
