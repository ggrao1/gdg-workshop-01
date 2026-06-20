#!/usr/bin/env pwsh
# run_local.ps1 — Windows equivalent of run_local.sh
# Starts the Course Creation Pipeline A2A agents and the ADK Web UI.

$ErrorActionPreference = "Stop"

# ── Load .env ────────────────────────────────────────────────────────────────
if (Test-Path ".env") {
    foreach ($line in Get-Content ".env") {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) { continue }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Length -eq 2) {
            $name = $parts[0].Trim()
            $value = $parts[1].Trim()
            # Remove surrounding quotes if present
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }
}

if (-not $env:GOOGLE_API_KEY) {
    Write-Host ""
    Write-Host "  ERROR: GOOGLE_API_KEY is not set." -ForegroundColor Red
    Write-Host "  Create a .env file:  cp .env.example .env" -ForegroundColor Red
    Write-Host "  Get a key at:        https://aistudio.google.com/api-keys" -ForegroundColor Red
    Write-Host ""
    exit 1
}

$env:GOOGLE_GENAI_USE_VERTEXAI = "False"

$AGENTS_DIR = Join-Path (Get-Location) "agents"

# ── Kill any existing processes on ports 8000-8004 ──────────────────────────
Write-Host ""
Write-Host "  Killing any existing processes on ports 8000-8004..."
try {
    $ports = 8000..8004
    foreach ($port in $ports) {
        $connections = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        foreach ($conn in $connections) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host "    Stopping $($proc.ProcessName) (PID $($proc.Id)) on port $port"
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
} catch {
    Write-Host "  (Could not auto-kill ports; continue anyway...)" -ForegroundColor Yellow
}

# ── Helper to start a background process ──────────────────────────────────
function Start-AgentProcess($Name, $Port, $Arguments) {
    Write-Host "  Starting $Name → port $Port"
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = "adk"
    $pinfo.Arguments = $Arguments
    $pinfo.UseShellExecute = $false
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.CreateNoWindow = $true
    $pinfo.WorkingDirectory = (Get-Location)
    $proc = [System.Diagnostics.Process]::Start($pinfo)
    return $proc
}

$processes = @()

$processes += Start-AgentProcess "Researcher" 8001 "api_server --port 8001 --host 0.0.0.0 `"$AGENTS_DIR/researcher`""
$processes += Start-AgentProcess "Judge" 8002 "api_server --port 8002 --host 0.0.0.0 `"$AGENTS_DIR/judge`""
$processes += Start-AgentProcess "Content Builder" 8003 "api_server --port 8003 --host 0.0.0.0 `"$AGENTS_DIR/content_builder`""

Write-Host "  Waiting for sub-agents to be ready..."
Start-Sleep -Seconds 4

$processes += Start-AgentProcess "Orchestrator (ADK Web UI)" 8000 "web --port 8000 --host 0.0.0.0 `"$AGENTS_DIR`""

Write-Host ""
Write-Host "  ✅ All agents running!" -ForegroundColor Green
Write-Host "     Researcher:      http://localhost:8001"
Write-Host "     Judge:           http://localhost:8002"
Write-Host "     Content Builder: http://localhost:8003"
Write-Host "     ADK Web UI:      http://localhost:8000  ← Open this"
Write-Host ""
Write-Host "  Press Ctrl+C to stop all agents."
Write-Host ""

# ── Cleanup on exit ─────────────────────────────────────────────────────────
function Stop-AllAgents {
    Write-Host ""
    Write-Host "  Stopping..."
    foreach ($proc in $processes) {
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch {}
        }
    }
    # Also make sure ports are free
    foreach ($port in 8000..8004) {
        try {
            Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object {
                Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    exit
}

# Handle Ctrl+C
$null = Register-EngineEvent -SourceIdentifier ([System.Management.Automation.PsEngineEvent]::Exiting) -Action {
    Stop-AllAgents
}

# Keep alive until user presses a key or Ctrl+C
try {
    while ($true) {
        foreach ($proc in $processes) {
            if ($proc.HasExited) {
                $stderr = $proc.StandardError.ReadToEnd()
                $stdout = $proc.StandardOutput.ReadToEnd()
                if ($stderr) { Write-Host "  ERROR: $($stderr)" -ForegroundColor Red }
                if ($stdout) { Write-Host "  OUTPUT: $($stdout)" }
                Write-Host "  A process exited unexpectedly. Stopping all agents." -ForegroundColor Red
                Stop-AllAgents
            }
        }
        Start-Sleep -Milliseconds 500
    }
} finally {
    Stop-AllAgents
}
