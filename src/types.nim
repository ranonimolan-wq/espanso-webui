## types.nim
## ========
## Espanso config tipleri — pragmatic yaklaşım.
##
## Tasarım kararı: espanso YAML schema çok geniş (form_fields, vars,
## image_path, html, markdown, regex, search_aliases, ...). Hepsini Nim
## tipine map'lemek = çok kod + çok bug. Bunun yerine:
##
## - Basit match'ler için: typed `SimpleMatch` (trigger + replace + word + propagate_case)
## - Kompleks match'ler için: raw YAML string (round-trip güvenli)
## - Config dosyaları: raw YAML string + birkaç gösterge alanı
##
## UI'da kullanıcı ister basit form kullanır, ister YAML edit etsin.

import os
import strutils
import strformat

# =====================================================================
#  SIMPLE MATCH (UI form ile düzenlenen)
# =====================================================================

type
  SimpleMatch* = object
    ## UI form'undan gelen minimal match verisi
    trigger*: string         # ":hello" gibi
    replace*: string         # "world" gibi (multi-line olabilir)
    word*: bool              # word: true (default false)
    propagateCase*: bool     # propagate_case: true
    uppercaseStyle*: string  # "capitalize_words" / "capitalize" / "uppercase" / ""

# =====================================================================
#  MATCH FILE (match/*.yml)
# =====================================================================

  MatchFile* = object
    path*: string           # absolute path
    name*: string           # "base.yml"
    relPath*: string        # config root'a göre relative
    isPrivate*: bool        # _ ile başlıyorsa true (auto-load edilmez)
    rawYaml*: string        # tüm dosyanın raw YAML'i (round-trip güvenli)
    matchCount*: int        # parse edilerek sayılan match sayısı

# =====================================================================
#  CONFIG FILE (config/default.yml + config/<app>.yml)
# =====================================================================

  AppConfigFile* = object
    path*: string
    name*: string           # "default" veya "vscode" gibi (uzantısız)
    isDefault*: bool
    rawYaml*: string        # tüm dosyanın raw YAML'i
    # hızlı erişim için parse edilen gösterge alanları
    backend*: string
    enable*: bool
    filterTitle*: string
    filterExec*: string
    filterClass*: string
    filterOs*: string

# =====================================================================
#  ESPANSO STATUS
# =====================================================================

  EspansoStatus* = object
    installed*: bool
    running*: bool
    version*: string
    configDir*: string
    runtimeDir*: string
    matchFileCount*: int
    configFileCount*: int
    totalMatchCount*: int
    # Debug info — UI'da gösterilir, sorun teşhisi için
    binPath*: string          ## Bulunan espanso binary yolu (boş = bulunamadı)
    searchLog*: seq[string]   ## Arama denemeleri
    processPath*: string      ## Process'in şu anki PATH'i

  ApiError* = object
    error*: string
    detail*: string

# =====================================================================
#  HELPERS
# =====================================================================

proc isPrivateFilename*(filename: string): bool =
  ## Dosya adı _ ile başlıyorsa private (auto-load edilmez)
  let name = filename.extractFilename()
  result = name.startsWith("_")

proc defaultBackendFor*(osName: string): string =
  ## OS'e göre önerilen backend
  case osName.toLowerAscii()
  of "linux": "Auto"
  of "macos", "darwin": "Auto"
  of "windows", "win32": "Clipboard"
  else: "Auto"
