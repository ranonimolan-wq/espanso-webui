## yaml_store.nim
## ===============
## Espanso YAML dosyalarını oku/yaz.
##
## Pragmatic yaklaşım: dosyaları raw YAML string olarak saklarız
## (round-trip güvenli). Sadece:
##   1. Match sayısını sayma (matches: altındaki - trigger: sayısı)
##   2. Yeni basit match ekleme (listeye - append)
##   3. Belirli bir trigger'ı silme/güncelleme
##   4. Config dosyalarından kilit alanları parse etme (backend, filter_*, enable)
##
## Kompleks düzenlemeler (vars, forms, regex) için UI'da raw YAML editör
## sağlarız — bu, espanso'nun tüm schema'sını Nim tipine map'lemekten
## çok daha güvenli.

import os
import strutils
import sequtils
import tables
import yaml
import yaml/dom
import yaml/stream
import types

# =====================================================================
#  LOW-LEVEL FILE I/O
# =====================================================================

proc readFileSafe*(path: string): tuple[ok: bool, content: string] =
  ## Dosyayı güvenli oku. Hata varsa ok=false.
  try:
    return (true, readFile(path))
  except:
    return (false, getCurrentExceptionMsg())

proc writeFileSafe*(path: string, content: string): tuple[
    ok: bool, err: string] =
  ## Dosyaya güvenli yaz. Önce tmp'e yaz, sonra rename (atomic).
  try:
    let dir = path.parentDir()
    if not dir.dirExists():
      createDir(dir)
    let tmp = path & ".tmp"
    writeFile(tmp, content)
    moveFile(tmp, path)
    return (true, "")
  except:
    return (false, getCurrentExceptionMsg())

# =====================================================================
#  MATCH COUNTING (lightweight parse)
# =====================================================================

proc countMatchesInYaml*(yamlContent: string): int =
  ## YAML'deki `matches:` altındaki `- trigger:` sayısını say.
  ## Tam YAML parser'dan daha hızlı ve bozuk dosyalara dayanıklı.
  ##
  ## Espanso match'leri şu formatta:
  ##   matches:
  ##     - trigger: ":hello"
  ##       replace: "world"
  ##     - trigger: ":bye"
  ##       replace: "see you"
  ##
  ## "trigger:" satırlarını sayarız ama sadece matches: bloğunda.
  var inMatchesBlock = false
  var inGlobalVarsBlock = false
  result = 0
  for line in yamlContent.splitLines():
    let stripped = line.strip()
    let indented = line.startsWith(" ") or line.startsWith("\t")

    # top-level anahtarlar
    if not indented:
      if stripped.startsWith("matches:"):
        inMatchesBlock = true
        inGlobalVarsBlock = false
      elif stripped.startsWith("global_vars:"):
        inGlobalVarsBlock = true
        inMatchesBlock = false
      elif stripped.len > 0 and not stripped.startsWith("#"):
        # başka bir top-level key
        inMatchesBlock = false
        inGlobalVarsBlock = false

    if inMatchesBlock and stripped.startsWith("- trigger:"):
      inc result
    elif inMatchesBlock and stripped.startsWith("- regex:"):
      # regex trigger da bir match
      inc result
    elif inMatchesBlock and stripped.startsWith("- form:"):
      # form shorthand de bir match
      inc result

# =====================================================================
#  MATCH APPEND (yeni match ekleme)
# =====================================================================

proc buildYamlMatchEntry*(m: SimpleMatch): string =
  ## SimpleMatch'i YAML entry'e çevir.
  ##
  ## Örnek çıktı:
  ##   - trigger: ":hello"
  ##     replace: "world"
  ##     word: true
  ##     propagate_case: true
  ##     uppercase_style: capitalize_words
  var lines: seq[string] = @[]

  # trigger her zaman tırnaklı (colon içerebilir)
  let t = m.trigger
  var triggerLine: string
  if t.contains("\"") or t.contains("\\"):
    # single-quote escape: ' -> ''
    let escaped = t.replace("'", "''")
    triggerLine = "  - trigger: '" & escaped & "'"
  else:
    triggerLine = "  - trigger: \"" & t & "\""
  lines.add(triggerLine)

  # replace — multi-line ise literal block (|), değilse tırnaklı string
  if m.replace.contains("\n"):
    # literal block syntax: |
    # YAML literal block body, "replace:" satırından daha girintili olmalı.
    # "replace:" 4 boşluk girintide, body 6 boşlukta olmalı.
    let bodyIndent = "      "
    var blockLines = m.replace.split("\n")
    # trailing newline varsa chomp indicator kullan
    var chomp = ""
    if blockLines.len > 0 and blockLines[^1] == "":
      blockLines = blockLines[0 ..< ^1]
      chomp = "-"  # strip trailing newline
    lines.add("    replace: |" & chomp)
    for bl in blockLines:
      lines.add(bodyIndent & bl)
  else:
    let r = m.replace
    if r.contains("\"") or r.contains("\\") or r.contains(":") or
       r.contains("#") or r.startsWith("{") or r.startsWith("["):
      # single-quote ile escape
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

  result = lines.join("\n")

proc appendMatchToYaml*(yamlContent: string, m: SimpleMatch): string =
  ## YAML dosyasına yeni match ekle. matches: bloğu varsa append,
  ## yoksa matches: bloğu oluşturur.
  ##
  ## Strateji:
  ## 1. matches: bloğu varsa, son match entry'sini bul, sonrasına ekle
  ## 2. matches: yoksa, dosyanın sonuna "matches:\n  - ..." ekle
  let entry = buildYamlMatchEntry(m)

  var lines = yamlContent.split("\n")
  # son newline varsa koru
  var hadTrailingNewline = false
  if lines.len > 0 and lines[^1] == "":
    hadTrailingNewline = true
    lines = lines[0 ..< ^1]

  # matches: bloğunu ara
  var matchesLineIdx = -1
  for i, line in lines:
    let stripped = line.strip()
    if stripped == "matches:" or stripped.startsWith("matches:"):
      let indent = line.len - stripped.len
      if indent == 0:  # top-level
        matchesLineIdx = i
        break

  if matchesLineIdx >= 0:
    # matches bloğu bulundu — son match entry'sini bul
    var lastEntryIdx = matchesLineIdx
    for i in (matchesLineIdx + 1) ..< lines.len:
      let stripped = lines[i].strip()
      # top-level key gelince blok biter
      let indented = lines[i].startsWith(" ") or lines[i].startsWith("\t")
      if not indented and stripped.len > 0 and not stripped.startsWith("#"):
        break
      if stripped.startsWith("- "):
        lastEntryIdx = i

    # lastEntryIdx sonrasına yeni entry ekle
    # ama önce lastEntryIdx'den itibaren entry'nin bittiği yeri bul
    # (entry birden fazla satır olabilir)
    var insertAfter = lastEntryIdx
    for i in (lastEntryIdx + 1) ..< lines.len:
      let stripped = lines[i].strip()
      let indented = lines[i].startsWith(" ") or lines[i].startsWith("\t")
      if not indented and stripped.len > 0 and not stripped.startsWith("#"):
        break
      if stripped.startsWith("- "):
        break
      insertAfter = i

    lines.insert(entry, insertAfter + 1)
  else:
    # matches bloğu yok — dosyanın sonuna ekle
    if lines.len > 0 and lines[^1].strip().len > 0:
      lines.add("")
    lines.add("matches:")
    lines.add(entry)

  result = lines.join("\n")
  if hadTrailingNewline:
    result.add("\n")

# =====================================================================
#  MATCH DELETE / UPDATE
# =====================================================================

type
  MatchLocation* = object
    startLine*: int  # entry'nin başladığı satır index
    endLine*: int    # entry'nin bittiği satır index (hariç)
    trigger*: string

proc findMatchEntries*(lines: seq[string], matchesBlockStart: int): seq[MatchLocation] =
  ## matches bloğundaki tüm entry'leri bul
  result = @[]
  var i = matchesBlockStart + 1
  while i < lines.len:
    let stripped = lines[i].strip()
    let indented = lines[i].startsWith(" ") or lines[i].startsWith("\t")
    if not indented and stripped.len > 0 and not stripped.startsWith("#"):
      break  # blok bitti
    if stripped.startsWith("- "):
      # entry başlangıcı
      var start = i
      # trigger'ı çek
      var trig = ""
      if "- trigger:" in lines[i]:
        trig = lines[i].split("trigger:", 1)[1].strip()
        # tırnakları temizle
        if trig.len >= 2 and ((trig[0] == '"' and trig[^1] == '"') or
                              (trig[0] == '\'' and trig[^1] == '\'')):
          trig = trig[1 ..< ^1]
      # entry'nin sonunu bul
      var j = i + 1
      while j < lines.len:
        let s2 = lines[j].strip()
        let ind2 = lines[j].startsWith(" ") or lines[j].startsWith("\t")
        if not ind2 and s2.len > 0 and not s2.startsWith("#"):
          break
        if s2.startsWith("- "):
          break  # yeni entry
        inc j
      result.add(MatchLocation(startLine: start, endLine: j, trigger: trig))
      i = j
    else:
      inc i

proc deleteMatchByTrigger*(yamlContent: string, trigger: string): tuple[
    ok: bool, newYaml: string, deleted: bool] =
  ## Belirli bir trigger'a sahip ilk match'i sil.
  ## Trigger'ı tam eşleşme ile arar (tırnaklar dahil edilmeden).
  result = (false, yamlContent, false)
  var lines = yamlContent.split("\n")
  var hadTrailingNewline = false
  if lines.len > 0 and lines[^1] == "":
    hadTrailingNewline = true
    lines = lines[0 ..< ^1]

  # matches: bloğunu bul
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
      # entry'i sil (startLine'dan endLine'a kadar)
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
#  CONFIG FILE PARSING (lightweight — sadece kilit alanlar)
# =====================================================================

proc parseConfigFile*(rawYaml: string): AppConfigFile =
  ## Config YAML'inden kilit alanları çek (backend, enable, filter_*)
  ## Tam parse etmez — regex/string search ile hızlı çalışır.
  result = AppConfigFile(rawYaml: rawYaml)
  for line in rawYaml.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("backend:"):
      result.backend = stripped.substr("backend:".len).strip()
      # tırnakları temizle
      if result.backend.len >= 2 and result.backend[0] == '"' and
         result.backend[^1] == '"':
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

# =====================================================================
#  MATCH FILE LISTING
# =====================================================================

proc listMatchFiles*(configDir: string): seq[MatchFile] =
  ## config/match/ altındaki tüm .yml ve .yaml dosyalarını listele
  ## (recursive). _ ile başlayanlar private olarak işaretlenir.
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
  ## config/config/ altındaki tüm .yml ve .yaml dosyalarını listele.
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

# =====================================================================
#  VALIDATION
# =====================================================================

proc isValidYaml*(content: string): tuple[ok: bool, err: string] =
  ## YAML syntax kontrolü. NimYAML ile parse etmeyi dener.
  ## loadAs[YamlNode] tüm YAML tiplerini parse edebilir.
  ## Not: NimYAML 2.2.1 GC-safe olmadığı için bu fonksiyon GC-safe değil.
  ## Async handler'lardan çağırırken `{.cast(gcsafe).}:` bloğu kullanın.
  try:
    let node = loadAs[YamlNode](content)
    discard node  # sadece parse ettir
    return (true, "")
  except YamlConstructionError as e:
    return (false, "YAML construction error: " & e.msg)
  except YamlParserError as e:
    return (false, "YAML parser error: " & e.msg)
  except:
    return (false, "YAML parse error: " & getCurrentExceptionMsg())

# =====================================================================
#  MATCH PARSING (NimYAML ile gerçek parse — frontend parser yerine)
# =====================================================================
## Bu fonksiyon frontend'deki parseMatchesFromYaml JS fonksiyonunun
## yerine geçer. NimYAML gerçek YAML parser olduğu için tüm edge case'leri
## handle eder: farklı indent, quote style, comments, multi-line, vb.
##
##返: (trigger, replace, word, propagateCase, uppercaseStyle, regex, form)
## tuple listesi. trigger boşsa match geçerli değil.

type
  ParsedMatch* = object
    trigger*: string
    replace*: string
    word*: bool
    propagateCase*: bool
    uppercaseStyle*: string
    regex*: string
    form*: string
    isForm*: bool
    fileName*: string

proc mapGet(node: YamlNode, key: string): YamlNode =
  ## YamlNode mapping'den string key ile değer al. Yoksa nil döner.
  if node.isNil or node.kind != yMapping:
    return nil
  let keyNode = newYamlNode(key)
  for k, v in node.fields:
    if k == keyNode:
      return v
  return nil

proc scalarContent(node: YamlNode): string =
  ## Scalar node'un content'ini döner. Mapping/Sequence ise "" döner.
  if node.isNil: return ""
  if node.kind == yScalar:
    return node.content
  return ""

proc parseMatchesFromYaml*(yamlContent: string, fileName: string = ""): seq[ParsedMatch] =
  ## NimYAML ile YAML'i parse et, matches listesini çıkar.
  ## Hata olursa boş seq döner (frontend'de error gösterilir).
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
      # trigger veya regex veya form varsa geçerli match
      if pm.trigger.len > 0 or pm.regex.len > 0 or pm.form.len > 0:
        result.add(pm)
  except:
    # Parse hatası — boş dön, frontend error gösterecek
    return @[]
