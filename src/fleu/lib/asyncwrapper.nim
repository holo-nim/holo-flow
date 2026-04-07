const asyncBackend {.strdefine.} = ""

when defined(js):
  import std/asyncjs
  export asyncjs
elif asyncBackend == "" or asyncBackend == "asyncdispatch":
  import std/[asyncdispatch, asyncstreams, asyncfile]
  export asyncdispatch, asyncstreams, asyncfile
elif asyncBackend == "chronos":
  when not (compiles do: import chronos):
    {.error: "async backend 'chronos' not installed".}
  import chronos
  export chronos
else:
  {.error: "unknown async backend " & asyncBackendDefine.}
