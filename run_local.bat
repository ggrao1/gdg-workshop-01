@echo off
:: run_local.bat — Windows wrapper for run_local.ps1
:: Starts the Course Creation Pipeline agents and the ADK Web UI.

powershell -ExecutionPolicy Bypass -File "%~dp0run_local.ps1"
