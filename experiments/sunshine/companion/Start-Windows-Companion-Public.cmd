@echo off
setlocal
pushd "%~dp0"
python.exe -B start_test_public.py %*
set "RESULT=%ERRORLEVEL%"
popd
if not "%RESULT%"=="0" pause
exit /b %RESULT%
