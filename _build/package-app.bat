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
echo [note] --format app stages the app only; the zip is assembled below with
echo        tar so it can carry the version-stamped release name.
echo        (Proton's own zip step works as of 0.9.0 too, but it deflates and
echo        names the archive after the product, not the version.)
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
echo === zip (scripts/make_zip.py, lock-safe) ===
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
rem The zip is built by scripts/make_zip.py, NOT by `tar -a`:
rem `tar -a -cf out.zip dir` on Windows' bsdtar ignores the extension and
rem writes a TAR, so the 0.2.17 release shipped a file named .zip that no
rem unzip tool could open. The script writes a real, deflated zip with
rem forward-slash entry names (187 MiB instead of 419 MiB for the same
rem tree).
where python >nul 2>&1
if errorlevel 1 (
  echo [error] python not found on PATH; it is needed by scripts\make_zip.py
  popd
  exit /b 1
)
python "%PROJ%\scripts\make_zip.py" "%APP%" "%ZIP%.new"
set "ZIP_RC=%errorlevel%"
rem Note: %errorlevel% is captured immediately after the call — `popd`
rem would reset it to 0 if we set ZIP_RC after.
if not %ZIP_RC% == 0 (
  echo [error] make_zip.py failed exit=%ZIP_RC%
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
echo === No entry-html mirror needed anymore ===
rem The mirror (Resources/frontend/dist -> frontend/dist) used to be
rem required because Proton's resolve_entry_path() resolves an
rem AppEntry::File against the CURRENT WORKING DIRECTORY. app/main.mbt
rem now uses @proton.asset, which resolves against the resource
rem directory (<exe dir>/Resources) instead — so the entry is found
rem whatever the cwd is, and the mirror is dead weight in the zip.
rem (The mirror used to be created AFTER the zip step, so the zip we
rem shipped did not even carry it and the app came up with no window.)

echo.
echo === Done ===
echo APP=%APP%
echo ZIP=%ZIP%
for %%I in ("%ZIP%") do echo zip-size=%%~zI bytes
popd
exit /b 0
