template doPeekBuffer*(buffer: cstring | string, nextPos: int, c: var char, result: var bool) =
  if nextPos < buffer.len:
    c = buffer[nextPos]
    result = true
  else:
    result = false
