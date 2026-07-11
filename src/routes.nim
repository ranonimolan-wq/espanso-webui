## routes.nim
## ===========
## Tüm HTTP route'ları. Prologue framework ile.
##
## Endpoint'ler:
##   GET  /                      → UI (index.html)
##   GET  /api/status            → espanso durum bilgisi
##   POST /api/restart           → espanso restart
##   POST /api/toggle            → enable/disable
##
##   GET  /api/match-files                  → tüm match dosyaları listele
##   GET  /api/match-files/:name            → tek dosya raw YAML
##   PUT  /api/match-files/:name            → dosyaya raw YAML yaz
##   POST /api/match-files                  → yeni match dosyası oluştur
##
##   GET  /api/matches          → tüm match'lerin özeti
##   POST /api/matches          → basit match ekle (SimpleMatch)
##   DELETE /api/matches        → trigger'a göre match sil
##
##   GET  /api/config-files                → config dosyalarını listele
##   GET  /api/config-files/:name          → config raw YAML
##   PUT  /api/config-files/:name          → config raw YAML yaz
##   POST /api/config-files                → yeni config dosyası oluştur

import prologue
import json
import strutils
import os
import types
import espanso_cli
import yaml_store

# =====================================================================
#  JSON HELPERS
# =====================================================================

proc jsonResponse*(ctx: Context, data: JsonNode, code = Http200) =
  ctx.response.setHeader("Content-Type", "application/json")
  resp data.pretty(2), code

proc errorResponse*(ctx: Context, msg: string, detail = "",
                    code = Http400) =
  let err = %*{"error": msg, "detail": detail}
  ctx.response.setHeader("Content-Type", "application/json")
  resp $err, code

# =====================================================================
#  SYSTEM STATUS
# =====================================================================

proc getStatus*(ctx: Context) {.async, gcsafe.} =
  var status: EspansoStatus
  {.cast(gcsafe).}:
    status = getFullStatus()
  var totalCount = 0
  var matchFileCount = 0
  var configFileCount = 0
  if status.configDir.len > 0:
    let matchFiles = listMatchFiles(status.configDir)
    let configFiles = listConfigFiles(status.configDir)
    matchFileCount = matchFiles.len
    configFileCount = configFiles.len
    for f in matchFiles:
      totalCount += f.matchCount

  # Debug info — her zaman döner (sorun teşhisi için)
  var searchLogArr = newJArray()
  for line in status.searchLog:
    searchLogArr.add(%line)

  let resp = %*{
    "installed": status.installed,
    "running": status.running,
    "version": status.version,
    "configDir": status.configDir,
    "runtimeDir": status.runtimeDir,
    "matchFileCount": matchFileCount,
    "configFileCount": configFileCount,
    "totalMatchCount": totalCount,
    # Debug info
    "debug": {
      "binPath": status.binPath,
      "processPath": status.processPath,
      "searchLog": searchLogArr
    }
  }
  if not status.installed:
    resp["warning"] = %("espanso binary bulunamadı. Detaylar için debug panelini açın.")
  elif status.configDir.len == 0:
    resp["warning"] = %("espanso yüklü ama config dizini bulunamadı. `espanso path config` çalışıyor mu?")
  elif not status.running:
    resp["warning"] = %("espanso yüklü ama daemon çalışmıyor. `espanso start` çalıştırın.")
  jsonResponse(ctx, resp)

proc restartEspansoHandler*(ctx: Context) {.async, gcsafe.} =
  let (ok, msg) = restartEspanso()
  let resp = %*{"success": ok, "message": msg}
  jsonResponse(ctx, resp, if ok: Http200 else: Http500)

proc toggleEspansoHandler*(ctx: Context) {.async, gcsafe.} =
  let bodyStr = ctx.request.body
  var enable = true
  try:
    let body = parseJson(bodyStr)
    enable = body["enable"].getBool()
  except:
    discard
  let (ok, msg) = toggleEspanso(enable)
  let resp = %*{"success": ok, "message": msg, "enabled": enable}
  jsonResponse(ctx, resp, if ok: Http200 else: Http500)

# =====================================================================
#  MATCH FILES
# =====================================================================

proc getMatchFiles*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı",
                  "espanso yüklü mü? `espanso path config` çalışıyor mu?",
                  Http500)
    return
  let files = listMatchFiles(status.configDir)
  var arr = newJArray()
  for f in files:
    arr.add(%*{
      "path": f.path,
      "name": f.name,
      "relPath": f.relPath,
      "isPrivate": f.isPrivate,
      "matchCount": f.matchCount,
      "rawYaml": f.rawYaml
    })
  let resp = %*{"files": arr, "total": files.len, "configDir": status.configDir}
  jsonResponse(ctx, resp)

proc createMatchFile*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let bodyStr = ctx.request.body
  var name, rawYaml: string
  try:
    let body = parseJson(bodyStr)
    name = body["name"].getStr()
    rawYaml = body.getOrDefault("rawYaml").getStr("")
  except:
    errorResponse(ctx, "Geçersiz JSON body", getCurrentExceptionMsg())
    return
  if name.len == 0:
    errorResponse(ctx, "name alanı gerekli", "")
    return
  # .yml ekle
  if not (name.endsWith(".yml") or name.endsWith(".yaml")):
    name = name & ".yml"
  let path = status.configDir / "match" / name
  if path.fileExists():
    errorResponse(ctx, "Dosya zaten var", path, Http409)
    return
  # default content
  let content = if rawYaml.len > 0: rawYaml else: "matches:\n"
  let (ok, err) = writeFileSafe(path, content)
  if not ok:
    errorResponse(ctx, "Dosya yazılamadı", err, Http500)
    return
  let resp = %*{"success": true, "path": path, "name": name}
  jsonResponse(ctx, resp, Http201)

proc updateMatchFile*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let bodyStr = ctx.request.body
  var name, rawYaml: string
  try:
    let body = parseJson(bodyStr)
    name = body["name"].getStr()
    rawYaml = body["rawYaml"].getStr()
  except:
    errorResponse(ctx, "Geçersiz JSON body", getCurrentExceptionMsg())
    return
  if name.len == 0:
    errorResponse(ctx, "name alanı gerekli", "")
    return
  let path = status.configDir / "match" / name
  if not path.fileExists():
    errorResponse(ctx, "Dosya yok", path, Http404)
    return
  # YAML validate (cast gcsafe: NimYAML GC-safe değil ama çalışma zamanında sorun yok)
  var valid: bool
  var errMsg: string
  {.cast(gcsafe).}:
    (valid, errMsg) = isValidYaml(rawYaml)
  if not valid:
    errorResponse(ctx, "Geçersiz YAML", errMsg)
    return
  let (ok, err) = writeFileSafe(path, rawYaml)
  if not ok:
    errorResponse(ctx, "Yazılamadı", err, Http500)
    return
  let resp = %*{"success": true, "path": path, "name": name,
                "matchCount": countMatchesInYaml(rawYaml)}
  jsonResponse(ctx, resp)

# =====================================================================
#  MATCHES (basit CRUD)
# =====================================================================

proc listAllMatches*(ctx: Context) {.async, gcsafe.} =
  ## Tüm match dosyalarındaki tüm match'leri özet olarak döner
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let files = listMatchFiles(status.configDir)
  var arr = newJArray()
  for f in files:
    if f.isPrivate: continue  # private dosyaları gizle
    arr.add(%*{
      "fileName": f.name,
      "relPath": f.relPath,
      "matchCount": f.matchCount,
      "isPrivate": f.isPrivate
    })
  let resp = %*{"files": arr, "total": files.len}
  jsonResponse(ctx, resp)

proc listAllMatchesParsed*(ctx: Context) {.async, gcsafe.} =
  ## Tüm match dosyalarını NimYAML ile parse edip flat match listesi döner.
  ## Frontend parser'ı yerine bu kullanılır — daha güvenilir.
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let files = listMatchFiles(status.configDir)
  var arr = newJArray()
  var totalParsed = 0
  var parseErrors = newJArray()
  for f in files:
    if f.isPrivate: continue
    # NimYAML GC-safe değil → cast(gcsafe) bloğu
    var parsed: seq[ParsedMatch]
    {.cast(gcsafe).}:
      parsed = parseMatchesFromYaml(f.rawYaml, f.name)
    if parsed.len == 0 and f.matchCount > 0:
      # Parse başarısız oldu (muhtemelen geçersiz YAML veya edge case)
      parseErrors.add(%*{
        "fileName": f.name,
        "matchCount": f.matchCount,
        "error": "Parse failed — YAML may have unsupported structure"
      })
    for pm in parsed:
      arr.add(%*{
        "trigger": pm.trigger,
        "replace": pm.replace,
        "word": pm.word,
        "propagateCase": pm.propagateCase,
        "uppercaseStyle": pm.uppercaseStyle,
        "regex": pm.regex,
        "form": pm.form,
        "isForm": pm.isForm,
        "file": pm.fileName
      })
      inc totalParsed
  let resp = %*{
    "matches": arr,
    "total": totalParsed,
    "parseErrors": parseErrors
  }
  jsonResponse(ctx, resp)

proc addSimpleMatch*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let bodyStr = ctx.request.body
  var m: SimpleMatch
  var targetFile: string
  try:
    let body = parseJson(bodyStr)
    m.trigger = body["trigger"].getStr()
    m.replace = body["replace"].getStr()
    m.word = body.getOrDefault("word").getBool(false)
    m.propagateCase = body.getOrDefault("propagateCase").getBool(false)
    m.uppercaseStyle = body.getOrDefault("uppercaseStyle").getStr("")
    targetFile = body.getOrDefault("file").getStr("base.yml")
  except:
    errorResponse(ctx, "Geçersiz JSON body", getCurrentExceptionMsg())
    return
  if m.trigger.len == 0:
    errorResponse(ctx, "trigger gerekli", "")
    return
  if not (targetFile.endsWith(".yml") or targetFile.endsWith(".yaml")):
    targetFile = targetFile & ".yml"
  let path = status.configDir / "match" / targetFile
  if not path.fileExists():
    errorResponse(ctx, "Hedef dosya yok", path, Http404)
    return
  let (ok, content) = readFileSafe(path)
  if not ok:
    errorResponse(ctx, "Dosya okunamadı", content, Http500)
    return
  let newContent = appendMatchToYaml(content, m)
  let (wok, werr) = writeFileSafe(path, newContent)
  if not wok:
    errorResponse(ctx, "Yazılamadı", werr, Http500)
    return
  let resp = %*{
    "success": true,
    "path": path,
    "trigger": m.trigger,
    "matchCount": countMatchesInYaml(newContent)
  }
  jsonResponse(ctx, resp, Http201)

proc deleteMatch*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let bodyStr = ctx.request.body
  var trigger, targetFile: string
  try:
    let body = parseJson(bodyStr)
    trigger = body["trigger"].getStr()
    targetFile = body.getOrDefault("file").getStr("base.yml")
  except:
    errorResponse(ctx, "Geçersiz JSON body", getCurrentExceptionMsg())
    return
  if trigger.len == 0:
    errorResponse(ctx, "trigger gerekli", "")
    return
  if not (targetFile.endsWith(".yml") or targetFile.endsWith(".yaml")):
    targetFile = targetFile & ".yml"
  let path = status.configDir / "match" / targetFile
  if not path.fileExists():
    errorResponse(ctx, "Dosya yok", path, Http404)
    return
  let (ok, content) = readFileSafe(path)
  if not ok:
    errorResponse(ctx, "Okunamadı", content, Http500)
    return
  let (rok, newYaml, deleted) = deleteMatchByTrigger(content, trigger)
  if not rok:
    errorResponse(ctx, "Silme hatası", newYaml, Http500)
    return
  if not deleted:
    errorResponse(ctx, "Trigger bulunamadı", trigger, Http404)
    return
  let (wok, werr) = writeFileSafe(path, newYaml)
  if not wok:
    errorResponse(ctx, "Yazılamadı", werr, Http500)
    return
  let resp = %*{
    "success": true,
    "trigger": trigger,
    "matchCount": countMatchesInYaml(newYaml)
  }
  jsonResponse(ctx, resp)

# =====================================================================
#  CONFIG FILES
# =====================================================================

proc getConfigFiles*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let files = listConfigFiles(status.configDir)
  var arr = newJArray()
  for f in files:
    arr.add(%*{
      "path": f.path,
      "name": f.name,
      "isDefault": f.isDefault,
      "rawYaml": f.rawYaml,
      "backend": f.backend,
      "enable": f.enable,
      "filterTitle": f.filterTitle,
      "filterExec": f.filterExec,
      "filterClass": f.filterClass,
      "filterOs": f.filterOs
    })
  let resp = %*{"files": arr, "total": files.len, "configDir": status.configDir}
  jsonResponse(ctx, resp)

proc updateConfigFile*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let bodyStr = ctx.request.body
  var name, rawYaml: string
  try:
    let body = parseJson(bodyStr)
    name = body["name"].getStr()
    rawYaml = body["rawYaml"].getStr()
  except:
    errorResponse(ctx, "Geçersiz JSON body", getCurrentExceptionMsg())
    return
  if name.len == 0:
    errorResponse(ctx, "name alanı gerekli", "")
    return
  let path = status.configDir / "config" / (name & ".yml")
  if not path.fileExists():
    errorResponse(ctx, "Dosya yok", path, Http404)
    return
  var valid: bool
  var errMsg: string
  {.cast(gcsafe).}:
    (valid, errMsg) = isValidYaml(rawYaml)
  if not valid:
    errorResponse(ctx, "Geçersiz YAML", errMsg)
    return
  let (ok, err) = writeFileSafe(path, rawYaml)
  if not ok:
    errorResponse(ctx, "Yazılamadı", err, Http500)
    return
  let resp = %*{"success": true, "path": path, "name": name}
  jsonResponse(ctx, resp)

proc createConfigFile*(ctx: Context) {.async, gcsafe.} =
  let status = getFullStatus()
  if status.configDir.len == 0:
    errorResponse(ctx, "espanso config dizini bulunamadı", "", Http500)
    return
  let bodyStr = ctx.request.body
  var name, rawYaml: string
  try:
    let body = parseJson(bodyStr)
    name = body["name"].getStr()
    rawYaml = body.getOrDefault("rawYaml").getStr("")
  except:
    errorResponse(ctx, "Geçersiz JSON body", getCurrentExceptionMsg())
    return
  if name.len == 0:
    errorResponse(ctx, "name gerekli", "")
    return
  let path = status.configDir / "config" / (name & ".yml")
  if path.fileExists():
    errorResponse(ctx, "Dosya zaten var", path, Http409)
    return
  let content = if rawYaml.len > 0: rawYaml else:
    "# App-specific config: " & name & "\nfilter_exec: \"" & name & "\"\nbackend: auto\n"
  let (ok, err) = writeFileSafe(path, content)
  if not ok:
    errorResponse(ctx, "Yazılamadı", err, Http500)
    return
  let resp = %*{"success": true, "path": path, "name": name}
  jsonResponse(ctx, resp, Http201)

# =====================================================================
#  ROUTE REGISTRATION
# =====================================================================

proc registerRoutes*(app: Prologue) =
  # System
  app.get("/api/status", getStatus)
  app.post("/api/restart", restartEspansoHandler)
  app.post("/api/toggle", toggleEspansoHandler)

  # Match files
  app.get("/api/match-files", getMatchFiles)
  app.post("/api/match-files", createMatchFile)
  app.post("/api/match-files/update", updateMatchFile)

  # Matches (simple CRUD)
  app.get("/api/matches", listAllMatches)
  app.get("/api/matches/list", listAllMatchesParsed)  # parsed match list
  app.post("/api/matches", addSimpleMatch)
  app.post("/api/matches/delete", deleteMatch)

  # Config files
  app.get("/api/config-files", getConfigFiles)
  app.post("/api/config-files", createConfigFile)
  app.post("/api/config-files/update", updateConfigFile)
