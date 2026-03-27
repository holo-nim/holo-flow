# "reader view" might be more accurate

import ./holo_reader, private/reader_common
import std/[streams, unicode] # just to expose API otherwise not used

const experimentalViewsAvailable = compiles do:
  var x: int
  let y: var int = y

const holoFlowImmediateReaderUseViews* {.booldefine.} = experimentalViewsAvailable

when defined(js):
  type ReaderState* = ref HoloReader
elif holoFlowImmediateReaderUseViews:
  type ReaderState* = var HoloReader
else:
  type ReaderState* = ptr HoloReader

type
  ImmediateReader* = object
    ## view type over the `HoloReader` type,
    ## to reduce pointer dereferences
    # XXX option to use normal string on js to force utf 8
    immediateBuffer*: cstring
    immediateLen*: int
    statePtr*: ReaderState

when defined(js):
  type AbsorbedState = HoloReader
  template state*(reader: ImmediateReader): HoloReader =
    reader.statePtr[]
  template `state=`*(reader: ImmediateReader, s: AbsorbedState) =
    reader.statePtr = cast[ReaderState](s)
elif ReaderState is ptr:
  type AbsorbedState = var HoloReader
  template state*(reader: ImmediateReader): var HoloReader =
    reader.statePtr[]
  template `state=`*(reader: ImmediateReader, s: AbsorbedState) =
    reader.statePtr = addr s
elif holoFlowImmediateReaderUseViews:
  type AbsorbedState = var HoloReader
  template state*(reader: ImmediateReader): var HoloReader =
    reader.statePtr
  template `state=`*(reader: ImmediateReader, s: AbsorbedState) =
    reader.statePtr = s
else:
  {.error: "unknown way to handle state type: " & $ReaderState.}

{.push checks: off, stacktrace: off.}

proc initImmediateReader*(original: AbsorbedState): ImmediateReader {.inline.} =
  result = ImmediateReader()
  result.state = original

proc startRead*(reader: var ImmediateReader, str: sink string) {.inline.} =
  reader.state.startRead(str)
  reader.immediateBuffer = cstring(reader.state.buffer)
  reader.immediateLen = reader.state.buffer.len
  inc reader.state.bufferLocks

proc startRead*(reader: var ImmediateReader, loader: BufferLoader, bufferCapacity = 32) {.inline.} =
  reader.state.startRead(loader, bufferCapacity)
  reader.immediateBuffer = nil

proc startRead*(reader: var ImmediateReader, stream: Stream, loadAmount = 16, bufferCapacity = 32) {.inline.} =
  reader.startRead(stream, loadAmount, bufferCapacity)
  reader.immediateBuffer = nil

when declared(File):
  proc startRead*(reader: var ImmediateReader, file: File, loadAmount = 16, bufferCapacity = 32) {.inline.} =
    reader.startRead(file, loadAmount, bufferCapacity)
    reader.immediateBuffer = nil

proc loadBufferOne*(reader: ImmediateReader) {.inline.} =
  if reader.immediateBuffer.isNil:
    reader.state.callBufferLoader()

proc loadBufferBy*(reader: ImmediateReader, n: int) {.inline.} =
  if reader.immediateBuffer.isNil:
    reader.state.callBufferLoaderBy(n)

proc peek*(reader: ImmediateReader, c: var char): bool {.inline.} =
  if reader.immediateBuffer.isNil:
    result = reader.state.peek(c)
  else:
    let nextPos = reader.state.bufferPos + 1
    doPeekBuffer(reader.immediateBuffer, nextPos, c, result)

proc unsafePeek*(reader: ImmediateReader): char {.inline.} =
  if reader.immediateBuffer.isNil:
    result = reader.state.unsafePeek()
  else:
    # this is extra unsafe
    result = reader.immediateBuffer[reader.state.bufferPos + 1]

proc peek*(reader: ImmediateReader, c: var char, offset: int): bool {.inline.} =
  if reader.immediateBuffer.isNil:
    result = reader.state.peek(c, offset)
  else:
    let nextPos = reader.state.bufferPos + 1 + offset
    doPeekBuffer(reader.immediateBuffer, nextPos, c, result)

proc unsafePeek*(reader: ImmediateReader, offset: int): char {.inline.} =
  if reader.immediateBuffer.isNil:
    result = reader.state.unsafePeek(offset)
  else:
    # this is extra unsafe
    result = reader.immediateBuffer[reader.state.bufferPos + 1 + offset]

proc peekCount*(reader: ImmediateReader, rune: var Rune): int {.inline.} =
  ## returns rune size if rune is peeked
  if reader.immediateBuffer.isNil:
    result = reader.state.peekCount(rune)
  else:
    let bpos = reader.state.bufferPos
    if bpos + 1 < reader.immediateLen:
      let start = reader.immediateBuffer[bpos + 1]
      result = 0
      let b = start.byte
      var n = 0
      if b shr 5 == 0b110:
        n = 1
      elif b shr 4 == 0b1110:
        n = 2
      elif b shr 3 == 0b11110:
        n = 3
      elif b shr 2 == 0b111110:
        n = 4
      elif b shr 1 == 0b1111110:
        n = 5
      else:
        return
      if bpos + 1 + n < reader.immediateLen:
        result = n
        fastRuneAt(reader.immediateBuffer.toOpenArray(0, reader.immediateLen - 1), bpos + 1, rune, doInc = false)

proc peek*(reader: ImmediateReader, rune: var Rune): bool {.inline.} =
  result = peekCount(reader, rune) != 0

template peekStrImpl(reader: ImmediateReader, cs) =
  if reader.immediateBuffer.isNil:
    result = reader.state.peek(cs)
  else:
    result = false
    let n = cs.len
    let bpos = reader.state.bufferPos
    if bpos + n < reader.immediateLen:
      result = true
      when nimvm:
        for i in 0 ..< n:
          cs[i] = reader.immediateBuffer[bpos + 1 + i]
      else:
        when not holoReaderPeekStrCopyMem or defined(js) or defined(nimscript):
          for i in 0 ..< n:
            cs[i] = reader.immediateBuffer[bpos + 1 + i]
        else:
          copyMem(addr cs[0], addr reader.immediateBuffer[bpos + 1], n)

proc peek*(reader: ImmediateReader, cs: var openArray[char]): bool {.inline.} =
  peekStrImpl(reader, cs)

proc peek*[I](reader: ImmediateReader, cs: var array[I, char]): bool {.inline.} =
  peekStrImpl(reader, cs)

proc peekOrZero*(reader: ImmediateReader): char {.inline.} =
  if not peek(reader, result):
    result = '\0'

proc hasNext*(reader: ImmediateReader): bool {.inline.} =
  var dummy: char
  result = peek(reader, dummy)

proc hasNext*(reader: ImmediateReader, offset: int): bool {.inline.} =
  var dummy: char
  result = peek(reader, dummy, offset)

proc lockBuffer*(reader: ImmediateReader) {.inline.} =
  if reader.immediateBuffer.isNil:
    reader.state.lockBuffer()

proc unlockBuffer*(reader: ImmediateReader) {.inline.} =
  if reader.immediateBuffer.isNil:
    reader.state.unlockBuffer()

proc unsafeNext*(reader: ImmediateReader) {.inline.} =
  reader.state.unsafeNext()

proc unsafeNextBy*(reader: ImmediateReader, n: int) {.inline.} =
  reader.state.unsafeNextBy(n)

proc next*(reader: ImmediateReader, c: var char): bool {.inline.} =
  if not peek(reader, c):
    return false
  result = true
  reader.state.unsafeNext(last = c)

proc next*(reader: ImmediateReader, rune: var Rune): bool {.inline.} =
  let size = peekCount(reader, rune)
  if size == 0:
    return false
  result = true
  reader.state.unsafeNext(last = rune)

proc next*(reader: ImmediateReader): bool {.inline.} =
  var dummy: char
  result = next(reader, dummy)

iterator peekNext*(reader: ImmediateReader): char =
  var c: char
  while reader.peek(c):
    yield c
    reader.unsafeNext()

proc peekMatch*(reader: ImmediateReader, c: char): bool {.inline.} =
  var c2: char
  if reader.peek(c2) and c2 == c:
    result = true
  else:
    result = false

proc nextMatch*(reader: ImmediateReader, c: char): bool {.inline.} =
  result = peekMatch(reader, c)
  if result:
    reader.unsafeNext()

proc peekMatch*(reader: ImmediateReader, c: char, offset: int): bool {.inline.} =
  if reader.immediateBuffer.isNil:
    result = reader.state.peekMatch(c, offset)
  else:
    let bpos = reader.state.bufferPos
    if bpos + 1 + offset < reader.immediateLen:
      if c != reader.immediateBuffer[bpos + 1 + offset]:
        return false
      result = true
    else:
      result = false

proc peekMatch*(reader: ImmediateReader, rune: Rune): bool {.inline.} =
  var rune2: Rune
  if reader.peek(rune2) and rune2 == rune:
    result = true
  else:
    result = false

proc nextMatch*(reader: ImmediateReader, rune: Rune): bool {.inline.} =
  result = peekMatch(reader, rune)
  if result:
    reader.unsafeNextBy(size(rune))

proc peekMatch*(reader: ImmediateReader, cs: set[char], c: var char): bool {.inline.} =
  if reader.peek(c) and c in cs:
    result = true
  else:
    result = false

proc nextMatch*(reader: ImmediateReader, cs: set[char], c: var char): bool {.inline.} =
  result = peekMatch(reader, cs, c)
  if result:
    reader.unsafeNext()

proc peekMatch*(reader: ImmediateReader, cs: set[char]): bool {.inline.} =
  var dummy: char
  result = reader.peekMatch(cs, dummy)

proc nextMatch*(reader: ImmediateReader, cs: set[char]): bool {.inline.} =
  var dummy: char
  result = reader.nextMatch(cs, dummy)

proc peekMatch*(reader: ImmediateReader, cs: set[char], offset: int, c: var char): bool {.inline.} =
  if reader.immediateBuffer.isNil:
    result = reader.state.peekMatch(cs, offset, c)
  else:
    let bpos = reader.state.bufferPos
    if bpos + 1 + offset < reader.immediateLen:
      let c2 = reader.immediateBuffer[bpos + 1 + offset]
      if c2 in cs:
        c = c2
        return true
      result = false
    else:
      result = false

proc peekMatch*(reader: ImmediateReader, cs: set[char], offset: int): bool {.inline.} =
  var dummy: char
  result = reader.peekMatch(cs, offset, dummy)

template peekMatchStrImpl(reader: ImmediateReader, str) =
  if reader.immediateBuffer.isNil:
    result = reader.state.peekMatch(str)
  else:
    let bpos = reader.state.bufferPos
    if bpos + str.len < reader.immediateLen:
      for i in 0 ..< str.len:
        if str[i] != reader.immediateBuffer[bpos + 1 + i]:
          return false
      result = true
    else:
      result = false

proc peekMatch*(reader: ImmediateReader, str: openArray[char]): bool {.inline.} =
  peekMatchStrImpl(reader, str)

proc peekMatch*[I](reader: ImmediateReader, str: array[I, char]): bool {.inline.} =
  peekMatchStrImpl(reader, str)

proc peekMatch*(reader: ImmediateReader, str: static string): bool {.inline.} =
  # maybe make a const array
  peekMatchStrImpl(reader, str)

proc nextMatch*(reader: ImmediateReader, str: openArray[char]): bool {.inline.} =
  result = peekMatch(reader, str)
  if result:
    reader.unsafeNextBy(str.len)

proc nextMatch*[I](reader: ImmediateReader, str: array[I, char]): bool {.inline.} =
  result = peekMatch(reader, str)
  if result:
    reader.unsafeNextBy(str.len)

proc nextMatch*(reader: ImmediateReader, str: static string): bool {.inline.} =
  result = peekMatch(reader, str)
  if result:
    reader.unsafeNextBy(str.len)

{.pop.}
