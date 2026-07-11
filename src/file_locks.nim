# file_locks.nim
# Small helper module for file lock handling used by yaml_store.nim

import locks
import tables

var _locksTable: Table[string, Lock]

proc ensureLocksTable() =
  if _locksTable.len == 0:
    _locksTable = initTable[string, Lock](seq[string]())

proc lockForPath(path: string): ptr Lock =
  ensureLocksTable()
  if not _locksTable.hasKey(path):
    var l: Lock
    initLock(l)
    _locksTable[path] = l
  return addr _locksTable[path]
