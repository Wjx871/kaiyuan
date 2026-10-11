@echo off
rem ------------------------------------------------------------------
rem  carnival-sync.cmd -- Task Scheduler entry point
rem
rem  Keep this file ASCII-only: cmd.exe reads .cmd files using the
rem  system ANSI code page, and non-ASCII bytes break parsing on a
rem  zh-CN Windows box.
rem
rem  Installed at: C:\inetpub\carnival-sync\carnival-sync.cmd
rem ------------------------------------------------------------------
setlocal
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0carnival-sync.ps1" %*
exit /b %ERRORLEVEL%
