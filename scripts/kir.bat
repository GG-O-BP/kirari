@echo off
setlocal enabledelayedexpansion
set "PA="
for /d %%d in ("%~dp0*") do set "PA=!PA! -pa "%%d\ebin""
erl %PA% -eval "kirari@@main:run(kirari)" -noshell -extra %*
