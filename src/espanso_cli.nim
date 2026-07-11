## espanso_cli.nim
## =================
## Espanso CLI sarmalayıcısı. Tüm espanso komutlarını buradan çağır.
##
## Önemli notlar:
## - `espanso path config` → config dizinini döner (tek doğru kaynak)
## - `espanso match list -j` → tüm match'lerin authoritative JSON listesi
## - `espanso status` → daemon çalışıyor mu?
## - `espanso restart` → daemon'u yeniden başlat (auto_restart yetmeyince)
## - `espanso path` → tüm yollar
##
## Hata yönetimi: espanso yüklü değilse tüm fonksiyonlar güvenli şekilde
## boş/false döner ve UI'da uyarı + debug bilgi gösterilir.

import os
import osproc
import strutils
import strformat
import json
import types
import streams

# =====================================================================
#  ESPANSO BINARY DETECTION
# =====================================================================
#
# Sorun: pm2 veya systemd altında çalışan process, kullanıcının shell
# PATH'ini miras almıyor olabilir. espanso genelde `~/.local/bin/espanso`'ya
# kurulur (espanso env-path register ile). Eğer process PATH'i kısıtlıysa
# (/usr/bin:/bin), espanso bulunamıyor.
#
# Çözüm:
# 1. Process başlarken PATH'e yaygın yerleri ekle
# 2. findEspansoBin() — findExe + yaygın yerleri dene, sonucu cache'le
# 3. execEspanso tam yol kullanarak çalıştır

var
  espansoBinPath {.threadvar.}: string  ## Cache'lenmiş espanso binary yolu
  espansoSearchLog {.threadvar.}: seq[string]  ## Arama denemeleri (debug için)

proc expandProcessPath*() =
  ## Process PATH'ine yaygın binary dizinlerini ekle.
  ## pm2/systemd altında kısıtlı PATH'i genişletir.
  var pathEntries: seq[string] = @[]
  let home = getHomeDir()

  # Yaygın binary dizinleri
  let candidates = [
    home & ".local/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/opt/homebrew/bin",  # macOS Apple Silicon
    "/usr/local/sbin",
    home & ".cargo/bin",  # Rust kurulumu
    "/snap/bin"
  ]

  for c in candidates:
    if dirExists(c) and c notin pathEntries:
      pathEntries.add(c)

  # Mevcut PATH'i parçala, yeni entries'lerle birleştir
  let currentPath = getEnv("PATH")
  for p in currentPath.split(":"):
    if p.len > 0 and p notin pathEntries:
      pathEntries.add(p)

  # Yeni PATH'i set et
  putEnv("PATH", pathEntries.join(":"))

proc findEspansoBin*(): string =
  ## espanso binary'sini bul. PATH'te yoksa yaygın yerleri dene.
  ## Sonuç cache'lenir (tekrar arama yapmaz).
  if espansoBinPath.len > 0 and fileExists(espansoBinPath):
    return espansoBinPath

  espansoSearchLog = @[]
  espansoSearchLog.add("Searching for espanso binary...")

  # 1. findExe ile PATH'te ara (şu anki PATH ile)
  let p = findExe("espanso")
  espansoSearchLog.add("findExe('espanso') = " & (if p.len > 0: p else: "(not found)"))
  if p.len > 0:
    espansoBinPath = p
    return p

  # 2. Yaygın kurulum yerlerini dene
  let home = getHomeDir()
  let candidates = [
    home & ".local/bin/espanso",
    "/usr/local/bin/espanso",
    "/usr/bin/espanso",
    "/opt/espanso/espanso",
    home & ".espanso/espanso",
    "/opt/homebrew/bin/espanso",
    "/snap/bin/espanso",
    "/snap/espanso/current/bin/espanso",
    # macOS app
    "/Applications/espanso.app/Contents/MacOS/espanso"
  ]

  for c in candidates:
    let exists = fileExists(c)
    espansoSearchLog.add("  check: " & c & " = " & (if exists: "EXISTS" else: "no"))
    if exists:
      espansoBinPath = c
      espansoSearchLog.add("  ✓ Found: " & c)
      return c

  espansoSearchLog.add("✗ espanso binary not found anywhere")
  return ""

proc getEspansoSearchLog*(): seq[string] =
  ## Debug için arama denemelerini döner
  result = espansoSearchLog

# =====================================================================
#  EXEC HELPER
# =====================================================================

proc execEspanso*(args: seq[string], timeoutMs = 8000): tuple[
    success: bool, output: string, exitCode: int] =
  ## espanso komutunu çalıştır. Binary bulunamazsa success=false döner.
  ## startProcess + poUsePath kullanır — PATH lookup yapar.
  let binPath = findEspansoBin()
  if binPath.len == 0:
    result = (false, "espanso binary not found. Search log:\n" &
              getEspansoSearchLog().join("\n"), -1)
    return

  try:
    let p = startProcess(binPath, args = args,
                         options = {poUsePath, poStdErrToStdOut})
    var outStr = ""
    let stream = p.outputStream
    if stream != nil:
      outStr = stream.readAll()
    let exitCode = waitForExit(p, timeoutMs)
    p.close()
    if exitCode == 0:
      result = (true, outStr, 0)
    else:
      result = (false, outStr, exitCode)
  except OSError:
    result = (false, "OSError: " & getCurrentExceptionMsg(), -1)
  except:
    result = (false, "Exception: " & getCurrentExceptionMsg(), -1)

# =====================================================================
#  PATH DETECTION
# =====================================================================

proc isEspansoInstalled*(): bool =
  ## espanso binary bulundu mu?
  let binPath = findEspansoBin()
  result = binPath.len > 0

proc getEspansoVersion*(): string =
  let (ok, output, _) = execEspanso(@["--version"], 3000)
  if ok:
    # "espanso 2.2.5" gibi bir satır döner
    for line in output.splitLines():
      let s = line.strip()
      if s.startsWith("espanso"):
        return s
  return ""

proc getEspansoConfigDir*(): string =
  ## `espanso path config` çıktısını döner. Hata varsa "" döner.
  let (ok, output, _) = execEspanso(@["path", "config"], 3000)
  if ok:
    # Çıktı: "/home/user/.config/espanso" veya path bilgisi
    for line in output.splitLines():
      let s = line.strip()
      if s.len > 0 and s.startsWith("/"):
        return s
      # "config: /path" formatında da gelebilir
      if "config" in s.toLowerAscii() and ":" in s:
        let parts = s.split(":", maxsplit = 1)
        if parts.len == 2:
          let p = parts[1].strip()
          if p.startsWith("/"):
            return p
  return ""

proc getEspansoRuntimeDir*(): string =
  let (ok, output, _) = execEspanso(@["path", "runtime"], 3000)
  if ok:
    for line in output.splitLines():
      let s = line.strip()
      if s.len > 0 and s.startsWith("/"):
        return s
  return ""

# =====================================================================
#  STATUS
# =====================================================================

proc isEspansoRunning*(): bool =
  let (ok, output, _) = execEspanso(@["status"], 3000)
  if not ok: return false
  # "espanso is running" veya benzeri bir mesaj arar
  let s = output.toLowerAscii()
  return "running" in s and not ("not running" in s)

# =====================================================================
#  RELOAD / RESTART
# =====================================================================

proc restartEspanso*(): tuple[success: bool, message: string] =
  let (ok, output, _) = execEspanso(@["restart"], 10000)
  if ok:
    return (true, output.strip())
  else:
    return (false, output.strip())

proc toggleEspanso*(enable: bool): tuple[success: bool, message: string] =
  let cmd = if enable: "enable" else: "disable"
  let (ok, output, _) = execEspanso(@["cmd", cmd], 5000)
  if ok:
    return (true, output.strip())
  else:
    return (false, output.strip())

# =====================================================================
#  MATCH LIST (authoritative JSON)
# =====================================================================

proc getEspansoMatchListJson*(): string =
  ## `espanso match list -j` çıktısını döner. Bu authoritative parsed
  ## JSON'dur — UI modelimizi validate etmek için kullanırız.
  let (ok, output, _) = execEspanso(@["match", "list", "-j"], 5000)
  if ok:
    return output
  return ""

# =====================================================================
#  FULL STATUS (debug info ile)
# =====================================================================

proc getFullStatus*(): EspansoStatus =
  ## Tüm espanso sistem durumunu bir kez topla
  let binPath = findEspansoBin()
  result = EspansoStatus(
    installed: binPath.len > 0,
    version: getEspansoVersion(),
    running: isEspansoRunning(),
    configDir: getEspansoConfigDir(),
    runtimeDir: getEspansoRuntimeDir(),
    matchFileCount: 0,
    configFileCount: 0,
    totalMatchCount: 0
  )
  # Debug info — UI'da gösterilecek
  result.binPath = binPath
  result.searchLog = getEspansoSearchLog()
  result.processPath = getEnv("PATH")
