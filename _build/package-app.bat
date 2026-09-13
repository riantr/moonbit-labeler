@echo off
setlocal enabledelayedexpansion
pushd "%~dp0.."
set PROJ=%CD%
set OUT=%PROJ%\target\proton-dist
set APP=%OUT%\moonbit-labeler
set ZIP=%OUT%\moonbit-labeler.zip
set PROTON_NO_UPDATE_CHECK=1
call "C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
  echo [error] vcvars64.bat failed
  popd
  exit /b 1
)
set "PATH=%PROJ%\_build\local-bin;C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Tools\Llvm\x64\bin;%PATH%"
set CC=clang
set CXX=clang++

echo cwd=%PROJ%
echo === proton_cli package --release --format app ===
echo.
echo [note] passing --format app to skip the upstream-broken zip step.
echo        See AGENTS.md "Build" section for the full story.
proton_cli package --release --output "%OUT%" --format app
if errorlevel 1 goto :err_package
goto :after_package
:err_package
echo [error] proton_cli package failed exit=%ERRORLEVEL%
popd
exit /b %ERRORLEVEL%
:after_package

if not exist "%APP%\" goto :err_no_app
goto :after_no_app
:err_no_app
echo [error] expected app dir not found: %APP%
popd
exit /b 1
:after_no_app

echo.
echo === tar (Windows built-in zip, lock-safe) ===
rem Pure-cmd flow — PowerShell 5.1 has a known native
rem runtime bug that emits a spurious "Access is denied"
rem to the console on process exit (the .NET ZipFile /
rem StreamReader finalisers race Defender's just-opened
rem read handle). 2>nul on a powershell invocation does
rem not suppress it because the write is via the native
rem console handle, not the process stderr fd. To avoid
rem the bug entirely, this script is plain cmd and only
rem uses the cmd built-ins + Windows tar.
rem
rem The cmd built-ins (del, ren, copy, tar) emit stderr
rem through normal process fds, so `>nul 2>&1` is
rem sufficient on every call. If you launch this bat
rem from a PowerShell wrapper and still see "Access is
rem denied." in the wrapper's stderr after the script
rem finishes successfully, that line is the PowerShell
rem 5.1 .NET finaliser race, NOT from this script.
rem Workaround: invoke with
rem   cmd /c "_build\package-app.bat" 2>&1 | ^
rem     findstr /v /c:"Access is denied."
rem (or filter "拒绝访问。" for the Chinese locale).
rem
rem Flow:
rem   1. delete the old zip (best effort; if it is held
rem      open by Defender / Indexer / Explorer the delete
rem      fails silently and we rename the locked zip out
rem      of the way — rename works on locked files because
rem      it only re-tags the directory entry);
rem   2. tar creates moonbit-labeler.zip.new in the same
rem      output directory, using -a (auto-format) and
rem      -C so the archive is a relative-path zip of the
rem      moonbit-labeler app dir;
rem   3. copy /Y overwrites the final zip atomically
rem      (CopyFileEx with COPY_FILE_FAIL_IF_EXISTS off,
rem      TRUNCATE_EXISTING_ON); the source (.new) is
rem      deleted after the copy succeeds.
del /q "%ZIP%.new" >nul 2>&1
pushd "%OUT%"
tar -a -cf "%ZIP%.new" -C "%OUT%" "moonbit-labeler" >nul 2>&1
set "TAR_RC=%errorlevel%"
popd
rem Note: %errorlevel% is captured immediately after tar —
rem `popd` would reset it to 0 if we set TAR_RC after.
if not %TAR_RC% == 0 (
  echo [error] tar failed exit=%TAR_RC%
  goto :err_zip
)
if exist "%ZIP%" (
  del /q "%ZIP%" >nul 2>&1
  if exist "%ZIP%" (
    ren "%ZIP%" "moonbit-labeler.stale.%RANDOM%%RANDOM%%RANDOM%.zip" >nul 2>&1
  )
)
rem `set /a` with a constant-zero is guaranteed to exit 0,
rem which resets the cmd errorlevel. We need that because
rem cmd's `if errorlevel N` is a ">= N" test (not equality),
rem and an earlier del/ren may have left a stale non-zero
rem errorlevel; the subsequent `if "%errorlevel%" NEQ "0"`
rem (string equality) then reacts only to the actual copy
rem result, not to a phantom failure from earlier in the
rem block.
set /a _rer=0
copy /Y "%ZIP%.new" "%ZIP%" >nul 2>&1
if "%errorlevel%" NEQ "0" (
  rem Defender / Search Indexer / Explorer thumbnail may
  rem be holding the just-written zip open for a brief
  rem window. Retry a few times with a short sleep before
  rem giving up. Each retry also resets the errorlevel so
  rem the test below sees only the current copy's result.
  set /a _retry=0
:retry_copy
  set /a _retry+=1
  if !_retry! GTR 10 (
    echo [error] copy .new to final zip failed after 10 retries
    goto :err_zip
  )
  timeout /t 1 /nobreak >nul
  set /a _rer=0
  copy /Y "%ZIP%.new" "%ZIP%" >nul 2>&1
  if "%errorlevel%" NEQ "0" goto :retry_copy
)
del /q "%ZIP%.new" >nul 2>&1
goto :after_zip
:err_zip
echo [error] tar/copy failed exit=%ERRORLEVEL%
popd
exit /b %ERRORLEVEL%
:after_zip

if not exist "%ZIP%" goto :err_no_zip
goto :after_no_zip
:err_no_zip
echo [error] expected zip not found: %ZIP%
popd
exit /b 1
:after_no_zip

echo.
echo === Copy Resources/frontend -> frontend (workaround for Proton 0.2.5) ===
rem Proton 0.2.5's resolve_entry_path() uses cwd-relative .resolve(),
rem so @proton.file("frontend/dist/index.html") looks at moonbit-labeler/frontend/
rem not moonbit-labeler/Resources/frontend/. We mirror the dist there so
rem the runtime can find the entry html regardless of cwd.
if exist "%APP%\frontend\dist\index.html" rmdir /s /q "%APP%\frontend\dist"
if not exist "%APP%\frontend" mkdir "%APP%\frontend"
if exist "%APP%\Resources\frontend\dist" xcopy /E /I /Q /Y "%APP%\Resources\frontend\dist" "%APP%\frontend\dist" >nul
if not exist "%APP%\frontend\dist\index.html" (
  echo [error] entry html mirror failed: %APP%\frontend\dist\index.html
  popd
  exit /b 1
)

echo.
echo === Done ===
echo APP=%APP%
echo ZIP=%ZIP%
for %%I in ("%ZIP%") do echo zip-size=%%~zI bytes
popd
exit /b 0
