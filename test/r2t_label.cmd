@echo off
setlocal enabledelayedexpansion

:: ============================================================================
::  raw2tracks_depad_labeled.cmd
:: ----------------------------------------------------------------------------
::  Merges raw2tracks.cmd + depad.cmd into a single SoX pass, and optionally
::  uses an ALSAmrec XML channel-label file to name the output tracks as:
::
::      <tracknumber> - <label>.wav
::
::  Example:
::      1 - kick.wav
::      2 - snare.wav
::
::  If no XML file is provided, or if a channel has no label in the XML, the
::  script falls back to:
::
::      <tracknumber> - channel <tracknumber>.wav
::
::  Expected XML format:
::      <channelLabels channels="32">
::        <channel index="1" label="kick"/>
::        <channel index="2" label="snare"/>
::      </channelLabels>
:: ============================================================================

:: ================= CONFIGURATION =================
set TARGET_BITS=24
set TARGET_ENCODING=signed-integer
:: =================================================

if "%~1"=="" (
    echo Usage: %~nx0 file1.raw [file2.raw] [...]
    echo Expected filename format: ^<timestamp^>_^<channels^>-^<rate^>-^<bitformat^>.raw
    exit /b 1
)

set "XMLLABELFILE="
echo.
echo Optional XML labels file selection
set /p "XMLLABELFILE=Enter XML labels file path, or press Enter to skip: "
if not "%XMLLABELFILE%"=="" (
    set "XMLLABELFILE=%XMLLABELFILE:\\=\%"
    set "XMLLABELFILE=%XMLLABELFILE:"=%"
    if not exist "%XMLLABELFILE%" (
        echo Warning: XML file "%XMLLABELFILE%" not found. Labels will be ignored.
        set "XMLLABELFILE="
    ) else (
        echo Using XML labels file: "%XMLLABELFILE%"
    )
)

for %%R in (%*) do (
    call :ProcessFile "%%~R"
)

echo.
echo All files processed.
pause
exit /b 0

:ProcessFile
set "RAWFILE=%~1"

set "TIMESTAMP="
set "CHANNELS="
set "RATE="
set "BITFORMAT="
set "BITS="
set "ENCODING="
set "ENDIAN="
set "OUT_BITS="
set "OUT_ENCODING="
set "DEPAD_APPLIED=0"

for %%F in ("%RAWFILE%") do set "BASENAME=%%~nF"

for /f "tokens=1* delims=_" %%a in ("%BASENAME%") do (
    set "TIMESTAMP=%%a"
    set "PARAMS=%%b"
)

if "%TIMESTAMP%"=="" (
    echo Error: Could not parse timestamp from filename "%RAWFILE%" - skipping.
    exit /b 1
)

for /f "tokens=1-3 delims=-" %%a in ("%PARAMS%") do (
    set "CHANNELS=%%a"
    set "RATE=%%b"
    set "BITFORMAT=%%c"
)

if "%CHANNELS%"=="" (
    echo Error: Could not parse channels from filename "%RAWFILE%" - skipping.
    exit /b 1
)
if "%RATE%"=="" (
    echo Error: Could not parse rate from filename "%RAWFILE%" - skipping.
    exit /b 1
)
if "%BITFORMAT%"=="" (
    echo Error: Could not parse bitformat from filename "%RAWFILE%" - skipping.
    exit /b 1
)

for %%F in (S8 U8 S16_LE S16_BE U16_LE U16_BE S24_LE S24_BE U24_LE U24_BE S32_LE S32_BE U32_LE U32_BE S24_3LE S24_3BE U24_3LE U24_3BE S20_3LE S20_3BE U20_3LE U20_3BE S18_3LE S18_3BE U18_3LE U18_3BE) do (
    if /i "!BITFORMAT!"=="%%F" (
        set "BITS=!BITFORMAT:~1,2!"
        if "!BITFORMAT:~0,1!"=="U" (
            set "ENCODING=unsigned-integer"
        ) else (
            set "ENCODING=signed-integer"
        )
        if "!BITFORMAT:~-2!"=="LE" set "ENDIAN=little"
        if "!BITFORMAT:~-2!"=="BE" set "ENDIAN=big"
    )
)

if /i "!BITFORMAT!"=="FLOAT_LE" (
    set "BITS=32"
    set "ENCODING=float"
    set "ENDIAN=little"
)
if /i "!BITFORMAT!"=="FLOAT_BE" (
    set "BITS=32"
    set "ENCODING=float"
    set "ENDIAN=big"
)
if /i "!BITFORMAT!"=="FLOAT64_LE" (
    set "BITS=64"
    set "ENCODING=float"
    set "ENDIAN=little"
)
if /i "!BITFORMAT!"=="FLOAT64_BE" (
    set "BITS=64"
    set "ENCODING=float"
    set "ENDIAN=big"
)

for %%F in (DSD_U8 DSD_U16_LE DSD_U16_BE DSD_U32_LE DSD_U32_BE DSD_U8_BE) do (
    if /i "!BITFORMAT!"=="%%F" (
        set "ENCODING=dsd"
        if "%%F"=="DSD_U8" set "BITS=8"
        if "%%F"=="DSD_U16_LE" set "BITS=16" & set "ENDIAN=little"
        if "%%F"=="DSD_U16_BE" set "BITS=16" & set "ENDIAN=big"
        if "%%F"=="DSD_U32_LE" set "BITS=32" & set "ENDIAN=little"
        if "%%F"=="DSD_U32_BE" set "BITS=32" & set "ENDIAN=big"
        if "%%F"=="DSD_U8_BE" set "BITS=8" & set "ENDIAN=big"
    )
)

if "%BITS%"=="" (
    echo Error: Unrecognized bitformat "%BITFORMAT%" in "%RAWFILE%" - skipping.
    exit /b 1
)

set "OUT_BITS=%BITS%"
set "OUT_ENCODING=%ENCODING%"

if /i "%ENCODING%"=="signed-integer" if %BITS% GTR %TARGET_BITS% (
    set "OUT_BITS=%TARGET_BITS%"
    set "OUT_ENCODING=%TARGET_ENCODING%"
    set "DEPAD_APPLIED=1"
)
if /i "%ENCODING%"=="unsigned-integer" if %BITS% GTR %TARGET_BITS% (
    set "OUT_BITS=%TARGET_BITS%"
    set "OUT_ENCODING=%TARGET_ENCODING%"
    set "DEPAD_APPLIED=1"
)

set "DEFAULT_OUTDIR=%TIMESTAMP%"
echo.
echo Destination directory selection for "%RAWFILE%"
echo You may enter a full or relative path, or press Enter to use the default: "%DEFAULT_OUTDIR%"
set /p "OUTDIR=Destination folder: "
if "%OUTDIR%"=="" set "OUTDIR=%DEFAULT_OUTDIR%"
set "OUTDIR=%OUTDIR:"=%"

if not exist "%OUTDIR%" (
    mkdir "%OUTDIR%" 2>nul
    if errorlevel 1 (
        echo Error: Failed to create destination directory "%OUTDIR%" - skipping "%RAWFILE%".
        exit /b 1
    )
)

if not exist "%OUTDIR%" (
    echo Error: Destination directory "%OUTDIR%" does not exist and could not be created - skipping "%RAWFILE%".
    exit /b 1
)

echo Extracting %CHANNELS% tracks from "%RAWFILE%" (%BITS%-bit %ENCODING%, %RATE% Hz, %ENDIAN% endian)
if "%DEPAD_APPLIED%"=="1" (
    echo Depadding: writing %OUT_BITS%-bit %OUT_ENCODING% output ^(source was %BITS%-bit - no intermediate file^)
) else (
    echo No depad needed: source is already %OUT_BITS%-bit %OUT_ENCODING%, extracting as-is.
)
echo Destination: "%OUTDIR%"
if not "%XMLLABELFILE%"=="" echo Labels XML: "%XMLLABELFILE%"

for /l %%C in (%CHANNELS%,-1,1) do (
    call :GetChannelLabel %%C TRACKLABEL
    call :SanitizeFileName "!TRACKLABEL!" SAFELABEL
    set "FILENAME=%%C - !SAFELABEL!.wav"
    echo - writing "%OUTDIR%\!FILENAME!"
    sox --type raw --bits %BITS% --channels %CHANNELS% --encoding %ENCODING% --rate %RATE% --endian %ENDIAN% "%RAWFILE%" --bits %OUT_BITS% --encoding %OUT_ENCODING% --endian little "%OUTDIR%\!FILENAME!" remix %%C
)

echo %CHANNELS% tracks successfully extracted ^(and depadded^) to "%OUTDIR%"!
exit /b 0

:GetChannelLabel
setlocal EnableDelayedExpansion
set "CH=%~1"
set "LABEL=channel %~1"

if not "%XMLLABELFILE%"=="" if exist "%XMLLABELFILE%" (
    for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "$xml = [xml](Get-Content -LiteralPath '%XMLLABELFILE%'); $n = $xml.channelLabels.channel ^| Where-Object { $_.index -eq '%~1' } ^| Select-Object -First 1; if ($n) { [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $n.label }"`) do (
        set "LABEL=%%L"
    )
)

endlocal & set "%~2=%LABEL%"
exit /b 0

:SanitizeFileName
setlocal EnableDelayedExpansion
set "NAME=%~1"
if "!NAME!"=="" set "NAME=channel"
set "NAME=!NAME:\=_!"
set "NAME=!NAME:/=_!"
set "NAME=!NAME::=_!"
set "NAME=!NAME:*=_%!"
set "NAME=!NAME:?=_!"
set "NAME=!NAME:"=_!"
set "NAME=!NAME:<=_!"
set "NAME=!NAME:>=_!"
set "NAME=!NAME:|=_!"
set "NAME=!NAME: = !"
:trimloop
if "!NAME:~-1!"=="." set "NAME=!NAME:~0,-1!" & goto trimloop
if "!NAME:~-1!"==" " set "NAME=!NAME:~0,-1!" & goto trimloop
if "!NAME!"=="" set "NAME=channel"
endlocal & set "%~2=%NAME%"
exit /b 0
