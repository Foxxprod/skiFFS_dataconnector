@echo off
rem Fermer tous les processus WindowsTerminal.exe
echo Fermeture de tous les processus WindowsTerminal.exe...
taskkill /F /IM WindowsTerminal.exe >nul 2>&1
echo Tous les processus WindowsTerminal.exe ont été fermés.

rem Fermer tous les processus python.exe
echo Fermeture de tous les processus python.exe...
taskkill /F /IM python.exe >nul 2>&1
echo Tous les processus python.exe ont été fermés.

exit
