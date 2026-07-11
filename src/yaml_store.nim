## yaml_store.nim
## ===============
## Espanso YAML dosyalarını oku/yaz. (stabilized write and safer append insertion)

import os
import strutils
import sequtils
import tables
import yaml
import yaml/dom
import types
import file_locks

# =====================================================================
#  LOW-LEVEL FILE I/O
# =====================================================================

proc readFileSafe*(path: string): tuple[ok: bool, content: string] =
  try:
    return (true, readFile(path))
  except:
    return (false, getCurrentExceptionMsg())

proc writeFileSafe*(path: string, content: string): tuple[ok: bool, err: string] =
  ## Safe write: ensure dir, take per-file lock, backup existing file (.bak),
  ## write tmp and move to target. Tmp name uses pid suffix if default tmp exists.
  try:
    let dir = path.parentDir()
    if not dir.dirExists():
      createDir(dir)

    let lptr = file_locks.lockForPath(path)
    lock(lptr[])
    try:
      if path.fileExists():
        try:
          let bak = path & ".bak"
          copyFile(path, bak)
        except:
          discard

      var tmp = path & ".tmp"
      if tmp.fileExists():
        tmp = path & ".tmp-" & $getProcessId()
      writeFile(tmp, content)
      moveFile(tmp, path)
    finally:
      unlock(lptr[])
    return (true, "")
  except:
    return (false, getCurrentExceptionMsg())

# =====================================================================
#  MATCH COUNTING (lightweight parse)
# =====================================================================

proc countMatchesInYaml*(yamlContent: string): int =
  var inMatchesBlock = false
  var inGlobalVarsBlock = false
  result = 0
  for line in yamlContent.splitLines():
    let stripped = line.strip()
    let indented = line.startsWith(" ") or line.startsWith("\t")

    if not indented:
      if stripped.startsWith("matches:"):
        inMatchesBlock = true
        inGlobalVarsBlock = false
      elif stripped.startsWith("global_vars:"):
        inGlobalVarsBlock = true
        inMatchesBlock = false
      elif stripped.len > 0 and not stripped.startsWith("#"):
        inMatchesBlock = false
        inGlobalVarsBlock = false

    if inMatchesBlock and (stripped.startsWith("- trigger:") or
                           stripped.startsWith("- regex:") or
                           stripped.startsWith("- form:")):
      inc result

# =====================================================================
#  MATCH APPEND (improved insertion)
# =====================================================================

proc buildYamlMatchEntry*(m: SimpleMatch): seq[string] =
  var lines: seq[string] = @[]
  let t = m.trigger
  var triggerLine: string
  if t.contains('"') or t.contains('\\'):
    let escaped = t.replace("'", "''")
    triggerLine = "  - trigger: '" & escaped & "'"
  else:
    triggerLine = "  - trigger: \"" & t & "\""
  lines.add(triggerLine)

  if m.replace.contains("\n"):
    let bodyIndent = "      "
    var blockLines = m.replace.split("\n")
    var chomp = ""
    if blockLines.len > 0 and blockLines[^1] == "":
      blockLines = blockLines[0 ..< ^1]
      chomp = "-"
    lines.add("    replace: |" & chomp)
    for bl in blockLines:
      lines.add(bodyIndent & bl)
  else:
    let r = m.replace
    if r.contains('"') or r.contains('\\') or r.contains(":" ) or
       r.contains("#") or r.startsWith("{") or r.startsWith("["):
      let escapedR = r.replace("'", "''")
      lines.add("    replace: '" & escapedR & "'")
    else:
      lines.add("    replace: \"" & r & "\"")

  if m.word:
    lines.add("    word: true")
  if m.propagateCase:
    lines.add("    propagate_case: true")
  if m.uppercaseStyle.len > 0:
    lines.add("    uppercase_style: " & m.uppercaseStyle)

  return lines

proc appendMatchToYaml*(yamlContent: string, m: SimpleMatch): string =
  ## Append by inserting entry lines into the file lines to keep indexes correct.
  let entryLines = buildYamlMatchEntry(m)

  var lines = yamlContent.split("\n")
  var hadTrailingNewline = false
  if lines.len > 0 and lines[^1] == "":
    hadTrailingNewline = true
    lines = lines[0 ..< ^1]

  var matchesLineIdx = -1
  for i, line in lines:
    let stripped = line.strip()
    if stripped == "matches:" or stripped.startsWith("matches:"):
      let indent = line.len - stripped.len
      if indent == 0:
        matchesLineIdx = i
        break

  if matchesLineIdx >= 0:
    var lastEntryIdx = matchesLineIdx
    for i in (matchesLineIdx + 1) ..< lines.len:
      let stripped = lines[i].strip()
      let indented = lines[i].startsWith(" ") or lines[i].startsWith("\t")
      if not indented and stripped.len > 0 and not stripped.startsWith("#"):
        break
      if stripped.startsWith("- "):
        lastEntryIdx = i

    var insertAfter = lastEntryIdx
    for i in (lastEntryIdx + 1) ..< lines.len:
      let stripped = lines[i].strip()
      let indented = lines[i].startsWith(" ") or lines[i].startsWith("\t")
      if not indented and stripped.len > 0 and not stripped.startsWith("#"):
        break
      if stripped.startsWith("- "):
        break
      insertAfter = i

    let head = lines[0 ..< insertAfter+1]
    let tail = if insertAfter + 1 < lines.len: lines[insertAfter+1 .. ^1] else: @[]
    lines = head & entryLines & tail
  else:
    if lines.len > 0 and lines[^1].strip().len > 0:
      lines.add("")
    lines.add("matches:")
    for l in entryLines: lines.add(l)

  var resultStr = lines.join("\n")
  if hadTrailingNewline:
    resultStr.add("\n")
  return resultStr

# =====================================================================
#  MATCH DELETE / UPDATE (unchanged)
# =====================================================================

type
  MatchLocation* = object
    startLine*: int
    endLine*: int
    trigger*: string

proc findMatchEntries*(lines: seq[string], matchesBlockStart: int): seq[MatchLocation] =
  result = @[]
  var i = matchesBlockStart + 1
  while i < lines.len:
    let stripped = lines[i].strip()
    let indented = lines[i].startsWith(" ") or lines[i].startsWith("\t")
    if not indented and stripped.len > 0 and not stripped.startsWith("#"):
      break
    if stripped.startsWith("- "):
      var start = i
      var trig = ""
      if "- trigger:" in lines[i]:
        trig = lines[i].split("trigger:", 1)[1].strip()
        if trig.len >= 2 and ((trig[0] == '"' and trig[^1] == '"') or
                              (trig[0] == '\'' and trig[^1] == '\'')):
          trig = trig[1 ..< ^1]
      var j = i + 1
      while j < lines.len:
        let s2 = lines[j].strip()
        let ind2 = lines[j].startsWith(" ") or lines[j].startsWith("\t")
        if not ind2 and s2.len > 0 and not s2.startsWith("#"):
          break
        if s2.startsWith("- "):
          break
        inc j
      result.add(MatchLocation(startLine: start, endLine: j, trigger: trig))
      i = j
    else:
      inc i

proc deleteMatchByTrigger*(yamlContent: string, trigger: string): tuple[ok: bool, newYaml: string, deleted: bool] =
  result = (false, yamlContent, false)
  var lines = yamlContent.split("\n")
  var hadTrailingNewline = false
  if lines.len > 0 and lines[^1] == "":
    hadTrailingNewline = true
    lines = lines[0 ..< ^1]

  var matchesLineIdx = -1
  for i, line in lines:
    let stripped = line.strip()
    if stripped == "matches:" or stripped.startsWith("matches:"):
      let indent = line.len - stripped.len
      if indent == 0:
        matchesLineIdx = i
        break

  if matchesLineIdx < 0:
    return (true, yamlContent, false)

  let entries = findMatchEntries(lines, matchesLineIdx)
  for entry in entries:
    if entry.trigger == trigger:
      var newLines: seq[string] = @[]
      for i, l in lines:
        if i < entry.startLine or i >= entry.endLine:
          newLines.add(l)
      var newYaml = newLines.join("\n")
      if hadTrailingNewline:
        newYaml.add("\n")
      return (true, newYaml, true)

  return (true, yamlContent, false)

# =====================================================================
#  CONFIG FILE PARSING & LISTING
# =====================================================================

proc parseConfigFile*(rawYaml: string): AppConfigFile =
  result = AppConfigFile(rawYaml: rawYaml)
  for line in rawYaml.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("backend:"):
      result.backend = stripped.substr("backend:".len).strip()
      if result.backend.len >= 2 and result.backend[0] == '"' and result.backend[^1] == '"':
        result.backend = result.backend[1 ..< ^1]
    elif stripped.startsWith("enable:"):
      let v = stripped.substr("enable:".len).strip().toLowerAscii()
      result.enable = v == "true"
    elif stripped.startsWith("filter_title:"):
      var v = stripped.substr("filter_title:".len).strip()
      if v.len >= 2 and v[0] == '"' and v[^1] == '"': v = v[1 ..< ^1]
      if v.len >= 2 and v[0] == '\'' and v[^1] == '\'': v = v[1 ..< ^1]
      result.filterTitle = v
    elif stripped.startsWith("filter_exec:"):
      var v = stripped.substr("filter_exec:".len).strip()
      if v.len >= 2 and v[0] == '"' and v[^1] == '"': v = v[1 ..< ^1]
      if v.len >= 2 and v[0] == '\'' and v[^1] == '\'': v = v[1 ..< ^1]
      result.filterExec = v
    elif stripped.startsWith("filter_class:"):
      var v = stripped.substr("filter_class:".len).strip()
      if v.len >= 2 and v[0] == '"' and v[^1] == '"': v = v[1 ..< ^1]
      if v.len >= 2 and v[0] == '\'' and v[^1] == '\'': v = v[1 ..< ^1]
      result.filterClass = v
    elif stripped.startsWith("filter_os:"):
      var v = stripped.substr("filter_os:".len).strip()
      if v.len >= 2 and v[0] == '"' and v[^1] == '"': v = v[1 ..< ^1]
      if v.len >= 2 and v[0] == '\'' and v[^1] == '\'': v = v[1 ..< ^1]
      result.filterOs = v

proc listMatchFiles*(configDir: string): seq[MatchFile] =
  result = @[]
  let matchDir = configDir / "match"
  if not matchDir.dirExists():
    return result

  for path in walkDirRec(matchDir):
    if not (path.endsWith(".yml") or path.endsWith(".yaml")):
      continue
    let name = path.extractFilename()
    let relPath = path.relativePath(configDir)
    let (ok, content) = readFileSafe(path)
    let yaml = if ok: content else: ""
    result.add(MatchFile(
      path: path,
      name: name,
      relPath: relPath,
      isPrivate: isPrivateFilename(name),
      rawYaml: yaml,
      matchCount: if ok: countMatchesInYaml(yaml) else: 0
    ))

proc listConfigFiles*(configDir: string): seq[AppConfigFile] =
  result = @[]
  let cfgDir = configDir / "config"
  if not cfgDir.dirExists():
    return result

  for path in walkDirRec(cfgDir):
    if not (path.endsWith(".yml") or path.endsWith(".yaml")):
      continue
    let name = path.extractFilename().changeFileExt("")
    let (ok, content) = readFileSafe(path)
    let yaml = if ok: content else: ""
    var cf = parseConfigFile(yaml)
    cf.path = path
    cf.name = name
    cf.isDefault = name == "default"
    result.add(cf)

proc isValidYaml*(content: string): tuple[ok: bool, err: string] =
  try:
    let node = loadAs[YamlNode](content)
    discard node
    return (true, "")
  except YamlConstructionError as e:
    return (false, "YAML construction error: " & e.msg)
  except YamlParserError as e:
    return (false, "YAML parser error: " & e.msg)
  except:
    return (false, "YAML parse error: " & getCurrentExceptionMsg())

proc parseMatchesFromYaml*(yamlContent: string, fileName: string = ""): seq[ParsedMatch] =
  result = @[]
  try:
    let root = loadAs[YamlNode](yamlContent)
    if root.isNil or root.kind != yMapping:
      return
    let matchesNode = root.mapGet("matches")
    if matchesNode.isNil or matchesNode.kind != ySequence:
      return
    for m in matchesNode.elems:
      if m.isNil or m.kind != yMapping:
        continue
      var pm = ParsedMatch(fileName: fileName)
      pm.trigger = scalarContent(m.mapGet("trigger"))
      pm.replace = scalarContent(m.mapGet("replace"))
      pm.regex = scalarContent(m.mapGet("regex"))
      pm.form = scalarContent(m.mapGet("form"))
      pm.isForm = pm.form.len > 0
      let wordNode = m.mapGet("word")
      if not wordNode.isNil and wordNode.kind == yScalar:
        pm.word = wordNode.content.toLowerAscii() == "true"
      let pcNode = m.mapGet("propagate_case")
      if not pcNode.isNil and pcNode.kind == yScalar:
        pm.propagateCase = pcNode.content.toLowerAscii() == "true"
      pm.uppercaseStyle = scalarContent(m.mapGet("uppercase_style"))
      if pm.trigger.len > 0 or pm.regex.len > 0 or pm.form.len > 0:
        result.add(pm)
  except:
    return @[]
