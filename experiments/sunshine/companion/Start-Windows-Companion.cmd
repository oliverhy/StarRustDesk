@echo off
setlocal
pushd "%~dp0"
python.exe -B windows_companion.py %*
set "RESULT=%ERRORLEVEL%"
popd
if not "%RESULT%"=="0" pause
exit /b %RESULT%
