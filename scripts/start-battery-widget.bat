@echo off
:: Controlla se lo script gira gia' come Amministratore
net session >nul 2>&1
if %errorlevel% == 0 (
    goto :run
) else (
    :: Rilancia se stesso richiedendo l'elevazione tramite UAC
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:run
start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0battery-widget.ps1"
