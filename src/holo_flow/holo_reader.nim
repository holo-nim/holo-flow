import ./stringresize
import std/[streams, unicode] # just to expose API otherwise not used

const holoReaderLineColumn* {.booldefine.} = true
  ## enables/disables line column tracking by default, has very little impact on performance

type
  BufferLoader* = proc (): string
  HoloReader* = object
    doLineColumn*: bool = holoReaderLineColumn
    buffer*: string
      ## buffer string, users need to access directly & keep track of position
    bufferLoader*: BufferLoader
      ## loads a string at a time to add to the buffer when needed
      ## set to nil after returning empty string
    freeBefore*: int
      ## position before which we can cull the buffer
    bufferLocks*: int
    bufferPos*: int
    line*, column*: int

{.push checks: off, stacktrace: off.}

proc initHoloReader*(doLineColumn = holoReaderLineColumn): HoloReader {.inline.} =
  result = HoloReader(doLineColumn: doLineColumn)

template startReadImpl() =
  reader.bufferPos = -1
  reader.bufferLocks = 0
  reader.line = 1
  reader.column = 1

proc startRead*(reader: var HoloReader, str: string) {.inline.} =
  reader.buffer = str
  reader.bufferLoader = nil
  startReadImpl()

proc startRead*(reader: var HoloReader, loader: BufferLoader, bufferCapacity = 32) {.inline.} =
  reader.buffer = newStringOfCap(bufferCapacity)
  reader.bufferLoader = loader

proc startRead*(reader: var HoloReader, stream: Stream, loadAmount = 16, bufferCapacity = 32) {.inline.} =
  let loader = proc (): string =
    readStr(stream, loadAmount)
  reader.startRead(loader, bufferCapacity)

when declared(File):
  proc startRead*(reader: var HoloReader, file: File, loadAmount = 16, bufferCapacity = 32) {.inline.} =
    ## `file` has to last as long as the reader
    var buf = newString(loadAmount) # save allocations by capturing this in the loader, array would need constant load amount
    let loader = proc (): string =
      let n = readChars(file, buf)
      buf.setLen(n)
      result = buf
    reader.startRead(loader, bufferCapacity)

proc loadBufferOne*(reader: var HoloReader) {.inline.} =
  if not reader.bufferLoader.isNil:
    let ex = reader.bufferLoader()
    if ex.len == 0:
      reader.bufferLoader = nil
      return
    let moved = reader.buffer.smartResizeAdd(ex, reader.freeBefore)
    if moved:
      reader.bufferPos -= reader.freeBefore
      reader.freeBefore = 0

proc loadBufferBy*(reader: var HoloReader, n: int) {.inline.} =
  if not reader.bufferLoader.isNil:
    var left = n
    while left > 0:
      let ex = reader.bufferLoader()
      if ex.len == 0:
        reader.bufferLoader = nil
        return
      let moved = reader.buffer.smartResizeAdd(ex, reader.freeBefore)
      if moved:
        reader.bufferPos -= reader.freeBefore
        reader.freeBefore = 0
      left -= ex.len

proc peek*(reader: var HoloReader, c: var char): bool {.inline.} =
  let nextPos = reader.bufferPos + 1
  if nextPos < reader.buffer.len:
    c = reader.buffer[nextPos]
    result = true
  elif reader.bufferLoader.isNil:
    result = false
  else:
    reader.loadBufferOne()
    if nextPos < reader.buffer.len:
      c = reader.buffer[nextPos]
      result = true
    else:
      result = false

proc unsafePeek*(reader: var HoloReader): char {.inline.} =
  result = reader.buffer[reader.bufferPos + 1]

proc peek*(reader: var HoloReader, c: var char, offset: int): bool {.inline.} =
  let nextPos = reader.bufferPos + 1 + offset
  if nextPos < reader.buffer.len:
    c = reader.buffer[nextPos]
    result = true
  elif reader.bufferLoader.isNil:
    result = false
  else:
    reader.loadBufferBy(1 + offset)
    if nextPos < reader.buffer.len:
      c = reader.buffer[nextPos]
      result = true
    else:
      result = false

proc unsafePeek*(reader: var HoloReader, offset: int): char {.inline.} =
  result = reader.buffer[reader.bufferPos + 1 + offset]

template prepareBuffer(reader: var HoloReader, n: int, offset = 0) =
  if not reader.bufferLoader.isNil:
    if reader.bufferPos + n + offset >= reader.buffer.len:
      reader.loadBufferBy(n)

proc peekCount*(reader: var HoloReader, rune: var Rune): int {.inline.} =
  ## returns rune size if rune is peeked
  var start: char
  if peek(reader, start):
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
    prepareBuffer(reader, n, offset = 1)
    if reader.bufferPos + 1 + n < reader.buffer.len:
      result = n
      fastRuneAt(reader.buffer, reader.bufferPos + 1, rune, doInc = false)

proc peek*(reader: var HoloReader, rune: var Rune): bool {.inline.} =
  result = peekCount(reader, rune) != 0

const holoReaderPeekStrCopyMem* {.booldefine.} = false
  ## possible minor optimization, seems slightly slower in practice 

template peekStrImpl(reader: var HoloReader, cs) =
  result = false
  let n = cs.len
  prepareBuffer(reader, n)
  let bpos = reader.bufferPos
  if bpos + n < reader.buffer.len:
    result = true
    when nimvm:
      for i in 0 ..< n:
        cs[i] = reader.buffer[bpos + 1 + i]
    else:
      when not holoReaderPeekStrCopyMem or defined(js) or defined(nimscript):
        for i in 0 ..< n:
          cs[i] = reader.buffer[bpos + 1 + i]
      else:
        copyMem(addr cs[0], addr reader.buffer[bpos + 1], n)

proc peek*(reader: var HoloReader, cs: var openArray[char]): bool {.inline.} =
  peekStrImpl(reader, cs)

proc peek*[I](reader: var HoloReader, cs: var array[I, char]): bool {.inline.} =
  peekStrImpl(reader, cs)

proc peekOrZero*(reader: var HoloReader): char {.inline.} =
  if not peek(reader, result):
    result = '\0'

proc hasNext*(reader: var HoloReader): bool {.inline.} =
  var dummy: char
  result = peek(reader, dummy)

proc hasNext*(reader: var HoloReader, offset: int): bool {.inline.} =
  var dummy: char
  result = peek(reader, dummy, offset)

proc lockBuffer*(reader: var HoloReader) {.inline.} =
  inc reader.bufferLocks

proc unlockBuffer*(reader: var HoloReader) {.inline.} =
  doAssert reader.bufferLocks > 0, "unpaired buffer unlock"
  dec reader.bufferLocks

proc unsafeNext*(reader: var HoloReader) {.inline.} =
  # keep separate from next for now
  let prevPos = reader.bufferPos
  inc reader.bufferPos
  if reader.doLineColumn:
    let c = reader.buffer[reader.bufferPos]
    if c == '\n' or (c == '\r' and reader.peekOrZero() != '\n'):
      inc reader.line
      reader.column = 1
    else:
      inc reader.column
  if reader.bufferLocks == 0: reader.freeBefore = prevPos

proc unsafeNextBy*(reader: var HoloReader, n: int) {.inline.} =
  # keep separate from next for now
  inc reader.bufferPos, n
  if reader.doLineColumn:
    for i in reader.bufferPos - n + 1 ..< reader.bufferPos:
      let c = reader.buffer[i]
      if c == '\n' or (c == '\r' and reader.buffer[i + 1] != '\n'):
        inc reader.line
        reader.column = 1
      else:
        inc reader.column
    let cf = reader.buffer[reader.bufferPos]
    if cf == '\n' or (cf == '\r' and reader.peekOrZero() != '\n'):
      inc reader.line
      reader.column = 1
    else:
      inc reader.column
  if reader.bufferLocks == 0: reader.freeBefore = reader.bufferPos - 1

proc next*(reader: var HoloReader, c: var char): bool {.inline.} =
  # keep separate from unsafeNext for now
  if not peek(reader, c):
    return false
  let prevPos = reader.bufferPos
  inc reader.bufferPos
  if reader.doLineColumn:
    if c == '\n' or (c == '\r' and reader.peekOrZero() != '\n'):
      inc reader.line
      reader.column = 1
    else:
      inc reader.column
  if reader.bufferLocks == 0: reader.freeBefore = prevPos
  result = true

proc next*(reader: var HoloReader, rune: var Rune): bool {.inline.} =
  let size = peekCount(reader, rune)
  if size == 0:
    return false
  let prevPos = reader.bufferPos
  inc reader.bufferPos, size
  if reader.doLineColumn:
    if rune == Rune('\n') or (rune == Rune('\r') and reader.peekOrZero() != '\n'):
      inc reader.line
      reader.column = 1
    else:
      inc reader.column
  if reader.bufferLocks == 0: reader.freeBefore = prevPos
  result = true

proc next*(reader: var HoloReader): bool {.inline.} =
  var dummy: char
  result = next(reader, dummy)

iterator peekNext*(reader: var HoloReader): char =
  var c: char
  while reader.peek(c):
    yield c
    reader.unsafeNext()

proc peekMatch*(reader: var HoloReader, c: char): bool {.inline.} =
  var c2: char
  if reader.peek(c2) and c2 == c:
    result = true
  else:
    result = false

proc nextMatch*(reader: var HoloReader, c: char): bool {.inline.} =
  result = peekMatch(reader, c)
  if result:
    reader.unsafeNext()

proc peekMatch*(reader: var HoloReader, c: char, offset: int): bool {.inline.} =
  prepareBuffer(reader, 1 + offset)
  let bpos = reader.bufferPos
  if bpos + 1 + offset < reader.buffer.len:
    if c != reader.buffer[bpos + 1 + offset]:
      return false
    result = true
  else:
    result = false

proc peekMatch*(reader: var HoloReader, rune: Rune): bool {.inline.} =
  var rune2: Rune
  if reader.peek(rune2) and rune2 == rune:
    result = true
  else:
    result = false

proc nextMatch*(reader: var HoloReader, rune: Rune): bool {.inline.} =
  result = peekMatch(reader, rune)
  if result:
    reader.unsafeNextBy(size(rune))

proc peekMatch*(reader: var HoloReader, cs: set[char], c: var char): bool {.inline.} =
  if reader.peek(c) and c in cs:
    result = true
  else:
    result = false

proc nextMatch*(reader: var HoloReader, cs: set[char], c: var char): bool {.inline.} =
  result = peekMatch(reader, cs, c)
  if result:
    reader.unsafeNext()

proc peekMatch*(reader: var HoloReader, cs: set[char]): bool {.inline.} =
  var dummy: char
  result = reader.peekMatch(cs, dummy)

proc nextMatch*(reader: var HoloReader, cs: set[char]): bool {.inline.} =
  var dummy: char
  result = reader.nextMatch(cs, dummy)

proc peekMatch*(reader: var HoloReader, cs: set[char], offset: int, c: var char): bool {.inline.} =
  prepareBuffer(reader, 1 + offset)
  let bpos = reader.bufferPos
  if bpos + 1 + offset < reader.buffer.len:
    let c2 = reader.buffer[bpos + 1 + offset]
    if c2 in cs:
      c = c2
      return true
    result = false
  else:
    result = false

proc peekMatch*(reader: var HoloReader, cs: set[char], offset: int): bool {.inline.} =
  var dummy: char
  result = reader.peekMatch(cs, offset, dummy)

template peekMatchStrImpl(reader: var HoloReader, str) =
  prepareBuffer(reader, str.len)
  let bpos = reader.bufferPos
  if bpos + str.len < reader.buffer.len:
    for i in 0 ..< str.len:
      if str[i] != reader.buffer[bpos + 1 + i]:
        return false
    result = true
  else:
    result = false

proc peekMatch*(reader: var HoloReader, str: openArray[char]): bool {.inline.} =
  peekMatchStrImpl(reader, str)

proc peekMatch*[I](reader: var HoloReader, str: array[I, char]): bool {.inline.} =
  peekMatchStrImpl(reader, str)

proc peekMatch*(reader: var HoloReader, str: static string): bool {.inline.} =
  # maybe make a const array
  peekMatchStrImpl(reader, str)

proc nextMatch*(reader: var HoloReader, str: openArray[char]): bool {.inline.} =
  result = peekMatch(reader, str)
  if result:
    reader.unsafeNextBy(str.len)

proc nextMatch*[I](reader: var HoloReader, str: array[I, char]): bool {.inline.} =
  result = peekMatch(reader, str)
  if result:
    reader.unsafeNextBy(str.len)

proc nextMatch*(reader: var HoloReader, str: static string): bool {.inline.} =
  result = peekMatch(reader, str)
  if result:
    reader.unsafeNextBy(str.len)

{.pop.}
