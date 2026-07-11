## espanso_webui.nim
## =================
## Espanso Web UI — main entry point.
##
## Kullanım:
##   ./espanso_webui              # http://localhost:7777
##   ./espanso_webui --port=8080
##   ./espanso_webui --host=0.0.0.0 --port=8080
##
## Statik dosyalar (HTML/CSS/JS) binary'nin yanındaki public/ klasöründen
## runtime'da okunur. Bu sayede:
##   - app.js değişikliği anında yansır (browser cache bypass)
##   - Binary yeniden derlenmesine gerek yok
##   - Kullanıcı frontend'i düzenleyebilir
##
## Binary nerede olursa olsun, public/ klasörünü bulur:
##   1. ./public/ (CWD)
##   2. binary'nin bulunduğu dizin/public/

import prologue
import std/parseopt
import std/strutils
import std/strformat
import std/os
import std/json
import routes
import espanso_cli  # expandProcessPath için

# =====================================================================
#  STARTUP — PATH genişletme
# =====================================================================
expandProcessPath()

# =====================================================================
#  PUBLIC DIRECTORY DETECTION
# =====================================================================
# Binary nerede olursa olsun public/ klasörünü bul.
# Önce CWD/public, sonra binary dizini/public dene.

proc findPublicDir(): string =
  let candidates = [
    getCurrentDir() / "public",
    getAppDir() / "public"
  ]
  for c in candidates:
    if dirExists(c):
      return c
  return candidates[0]

# =====================================================================
#  STATIC FILE SERVING (diskten okur)
# =====================================================================

proc staticFileHandler*(ctx: Context) {.async, gcsafe.} =
  ## public/ altındaki statik dosyaları diskten oku ve serve et.
  let pubDir = findPublicDir()  # her istekte hesapla (GC-safe)
  let reqPath = ctx.request.path.strip(chars = {'/'})

  if ".." in reqPath:
    resp "403 Forbidden", Http403
    return

  var filePath = if reqPath.len == 0: "index.html" else: reqPath
  let absPath = pubDir / filePath

  if not fileExists(absPath):
    resp "404 Not Found: " & filePath, Http404
    return

  let content = readFile(absPath)
  let ext = absPath.splitFile().ext.toLowerAscii()
  let ct = case ext
    of ".html": "text/html; charset=utf-8"
    of ".css": "text/css; charset=utf-8"
    of ".js": "application/javascript; charset=utf-8"
    of ".json": "application/json; charset=utf-8"
    of ".svg": "image/svg+xml"
    of ".png": "image/png"
    of ".ico": "image/x-icon"
    else: "application/octet-stream"
  ctx.response.setHeader("Content-Type", ct)
  ctx.response.setHeader("Cache-Control", "no-store, no-cache, must-revalidate")
  resp content, Http200

# =====================================================================
#  MAIN
# =====================================================================

var
  host = "127.0.0.1"
  port = 7777
  numThreads = 1

# CLI arg parse
var p = initOptParser(commandLineParams())
for kind, key, val in p.getopt():
  case kind
  of cmdLongOption, cmdShortOption:
    case key.toLowerAscii()
    of "host": host = val
    of "port", "p": port = parseInt(val)
    of "threads", "t": numThreads = parseInt(val)
    of "h", "help":
      echo "espanso_webui - Web UI for espanso"
      echo ""
      echo "Usage: espanso_webui [--host=HOST] [--port=PORT] [--threads=N]"
      echo ""
      echo "Options:"
      echo "  --host=HOST     Bind address (default: 127.0.0.1)"
      echo "  --port=PORT     Port (default: 7777)"
      echo "  --threads=N     Worker thread count (default: 1)"
      echo "  -h, --help      Show this help"
      quit(0)
  else: discard

# App setup
let settings = newSettings(
  appName = "espanso-webui",
  address = host,
  port = Port(port),
  debug = false,
  data = %*{
    "prologue": {
      "secretKey": "espanso-webui-dev-key",
      "appName": "espanso-webui",
      "numThreads": numThreads
    }
  }
)

var app = newApp(settings)

# API routes
app.registerRoutes()

# Static files (UI) — diskten serve edilir
app.get("/", staticFileHandler)
app.get("/index.html", staticFileHandler)
app.get("/style.css", staticFileHandler)
app.get("/app.js", staticFileHandler)

echo "╔══════════════════════════════════════════════════════════╗"
echo "║                                                          ║"
echo "║   espanso Web UI                                         ║"
echo "║   ─────────────────────────────────────────────────────  ║"
echo fmt"║   Listening: http://{host}:{port}                       ║"
echo fmt"║   Public dir: {findPublicDir()}"
echo fmt"║   Threads: {numThreads}                                          ║"
echo "║                                                          ║"
echo "║   CTRL+C to stop                                         ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"

app.run()

