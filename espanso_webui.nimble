# Package

version       = "0.1.0"
author        = "p4antom"
description   = "Web UI for espanso - manage matches & config without touching YAML"
license       = "MIT"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["espanso_webui"]

# Dependencies

requires "nim >= 2.2.0"
requires "prologue >= 0.6.0"
requires "yaml >= 2.2.0"

# Tasks

task run, "Run the server":
  setCommand "c", "src/espanso_webui.nim"
  switch "outdir", "build"
  switch "-d:release"

task debug, "Run the server (debug)":
  setCommand "c", "src/espanso_webui.nim"
  switch "outdir", "build"
  switch "-d:debug"
  switch "--stacktrace"
  switch "--lineTrace"
