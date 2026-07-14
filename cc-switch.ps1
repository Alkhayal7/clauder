#!/usr/bin/env pwsh
# clauder installer (Windows / PowerShell)
# Mirrors cc-switch.sh: provider switching + multi-account support for Claude Code.

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'update', 'uninstall', 'status')]
    [string]$Command = 'install',
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

$DataDir     = Join-Path $HOME '.clauder'
$WrapperPath = Join-Path $DataDir 'clauder.ps1'
$ConfPath    = Join-Path $HOME '.claude_providers.ini'
$ProfilePath = $PROFILE.CurrentUserAllHosts
$BeginMarker = '# >>> clauder >>>'
$EndMarker   = '# <<< clauder <<<'

function Write-TextFile($path, $content) {
    # UTF-8 without BOM, so the Claude CLI parses settings.json cleanly.
    [System.IO.File]::WriteAllText($path, $content)
}

# ------------------------------------------------------------------
# The wrapper. Installed as a profile-sourced function named `claude`
# that intercepts calls, applies the provider/account, then execs the
# real CLI. Single-quoted here-string => contents stay literal.
# ------------------------------------------------------------------
$WrapperContent = @'
# clauder wrapper - provider & account switching for Claude Code.
function claude {
    $configFile = if ($env:CLAUDE_CONF) { $env:CLAUDE_CONF } else { Join-Path $HOME '.claude_providers.ini' }
    $providerKeys = @(
        'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
        'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL'
    )

    function ConvertTo-Hashtable($obj) {
        if ($null -eq $obj) { return $null }
        if ($obj -is [pscustomobject]) {
            $h = [ordered]@{}
            foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hashtable $p.Value }
            return $h
        }
        if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
            $arr = @()
            foreach ($item in $obj) { $arr += , (ConvertTo-Hashtable $item) }
            return , $arr   # unary comma: preserve arrays (incl. empty) across return
        }
        return $obj
    }

    function Get-IniSections($path) {
        $sections = [ordered]@{}
        if (-not (Test-Path -LiteralPath $path)) { return $sections }
        $current = $null
        foreach ($line in Get-Content -LiteralPath $path) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith('#') -or $t.StartsWith(';')) { continue }
            if ($t -match '^\[(.+)\]$') { $current = $Matches[1].Trim(); $sections[$current] = [ordered]@{} }
            elseif ($current -and $t -match '^([^=]+)=(.*)$') {
                $sections[$current][$Matches[1].Trim()] = $Matches[2].Trim()
            }
        }
        return $sections
    }

    function Expand-ConfigDir($dir) {
        if ($dir -like '~*') { return Join-Path $HOME ($dir.Substring(1).TrimStart('/', '\')) }
        return $dir
    }

    function Write-Settings($settingsPath, $envUpdates, $removeKeys) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null
        $data = [ordered]@{}
        if (Test-Path -LiteralPath $settingsPath) {
            $raw = Get-Content -LiteralPath $settingsPath -Raw
            if ($raw -and $raw.Trim()) {
                try { $data = ConvertTo-Hashtable ($raw | ConvertFrom-Json) }
                catch { Write-Host "X Failed to parse $settingsPath" -ForegroundColor Red; return $false }
            }
        }
        if (-not $data.Contains('env')) { $data['env'] = [ordered]@{} }
        foreach ($k in $removeKeys) { if ($data['env'].Contains($k)) { $data['env'].Remove($k) } }
        foreach ($k in $envUpdates.Keys) { if ($envUpdates[$k]) { $data['env'][$k] = $envUpdates[$k] } }
        if ($data['env'].Count -eq 0) { $data.Remove('env') }
        if (-not $data.Contains('permissions')) { $data['permissions'] = [ordered]@{ allow = @(); deny = @() } }
        if (-not $data.Contains('alwaysThinkingEnabled')) { $data['alwaysThinkingEnabled'] = $true }
        [System.IO.File]::WriteAllText($settingsPath, ($data | ConvertTo-Json -Depth 20))
        return $true
    }

    $rest = @($args)

    # ---- --list ----
    if ($rest.Count -ge 1 -and $rest[0] -eq '--list') {
        if (Test-Path -LiteralPath $configFile) {
            Write-Host "Available Claude providers in ${configFile}:"
            $sections = Get-IniSections $configFile
            foreach ($name in $sections.Keys) {
                $dir = $sections[$name]['CLAUDE_CONFIG_DIR']
                if ($dir) { Write-Host "  - $name  (account: $dir)" } else { Write-Host "  - $name" }
            }
        } else {
            Write-Host "Config file not found: $configFile"
        }
        Write-Host ""
        Write-Host "Accounts:"
        if (Test-Path -LiteralPath (Join-Path $HOME '.claude')) {
            Write-Host "  - (default)  ~/.claude   # plain 'claude' with no @name"
        } else {
            Write-Host "  - (default)  ~/.claude   # plain 'claude'; created on first run"
        }
        Get-ChildItem -LiteralPath $HOME -Directory -Filter '.claude-*' -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $n = $_.Name.Substring('.claude-'.Length)
            Write-Host ("  - `"@{0}`"  ~/.claude-{0}" -f $n)
        }
        Write-Host ""
        Write-Host "Usage: claude [args...]                       # default account (~/.claude)"
        Write-Host "       claude <provider> [args...]            # switch provider"
        Write-Host "       claude `"@<name>`" [provider] [args...]  # named account (quote @ in PowerShell)"
        return
    }

    $configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }

    # ---- @account: isolate this session in its own config dir ----
    if ($rest.Count -ge 1 -and $rest[0] -match '^@([A-Za-z0-9_-]+)$') {
        $acct = $Matches[1]
        $configDir = Join-Path $HOME ".claude-$acct"
        $env:CLAUDE_CONFIG_DIR = $configDir
        New-Item -ItemType Directory -Force -Path $configDir | Out-Null
        Write-Host ">>> Using account: @$acct ($configDir)"
        $rest = @($rest | Select-Object -Skip 1)
    }

    $settingsPath = Join-Path $configDir 'settings.json'

    # ---- provider section? ----
    $provider = $null
    if ($rest.Count -ge 1 -and $rest[0] -match '^[A-Za-z0-9_-]+$') {
        $sections = Get-IniSections $configFile
        if ($sections.Contains($rest[0])) {
            $provider = $rest[0]
            $rest = @($rest | Select-Object -Skip 1)
        }
    }

    if ($provider) {
        $sec = (Get-IniSections $configFile)[$provider]

        # A section may pin its own CLAUDE_CONFIG_DIR (named account preset).
        $dirOverride = $sec['CLAUDE_CONFIG_DIR']
        if ($dirOverride) {
            $dirOverride = Expand-ConfigDir $dirOverride
            $env:CLAUDE_CONFIG_DIR = $dirOverride
            New-Item -ItemType Directory -Force -Path $dirOverride | Out-Null
            $settingsPath = Join-Path $dirOverride 'settings.json'
            Write-Host ">>> Using account: $provider ($dirOverride)"
        }

        $auth = $sec['ANTHROPIC_AUTH_TOKEN']; if (-not $auth) { $auth = $sec['API_KEY'] }
        $base = $sec['ANTHROPIC_BASE_URL'];   if (-not $base) { $base = $sec['BASE_URL'] }

        if (-not $auth -and -not $base) {
            if ($dirOverride) {
                # Account-only section: official login isolated in its own dir.
                Write-Settings $settingsPath @{} $providerKeys | Out-Null
            } else {
                Write-Host "X Section [$provider] defines neither provider keys nor CLAUDE_CONFIG_DIR." -ForegroundColor Red
                return
            }
        } else {
            $missing = @()
            if (-not $auth) { $missing += 'ANTHROPIC_AUTH_TOKEN' }
            if (-not $base) { $missing += 'ANTHROPIC_BASE_URL' }
            if ($missing.Count -gt 0) {
                Write-Host "X Provider [$provider] incomplete (missing: $($missing -join ', '))." -ForegroundColor Red
                return
            }
            $updates = [ordered]@{
                ANTHROPIC_AUTH_TOKEN           = $auth
                ANTHROPIC_BASE_URL             = $base
                ANTHROPIC_DEFAULT_SONNET_MODEL = $sec['ANTHROPIC_DEFAULT_SONNET_MODEL']
                ANTHROPIC_DEFAULT_HAIKU_MODEL  = $sec['ANTHROPIC_DEFAULT_HAIKU_MODEL']
                ANTHROPIC_DEFAULT_OPUS_MODEL   = $sec['ANTHROPIC_DEFAULT_OPUS_MODEL']
            }
            if (-not (Write-Settings $settingsPath $updates @())) { return }
            Write-Host ">>> Using provider: $provider"
        }
    } else {
        # No provider - strip any previously injected provider env.
        Write-Settings $settingsPath @{} $providerKeys | Out-Null
    }

    # ---- locate the official CLI (exclude this function) and run it ----
    $real = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $real) {
        Write-Host "Official Claude CLI not found. Install: irm https://claude.ai/install.ps1 | iex" -ForegroundColor Red
        return
    }
    & $real.Source @rest
}
'@

$SampleConf = @'
# Providers (Anthropic-compatible API)
# Usage: claude <provider_name> [args...]
#        claude [args...] (uses official Anthropic Claude)

# Accounts - run multiple Claude Code logins side by side.
# Prefix any name with @ (e.g. 'claude @work') for an ad-hoc account.
# Or pin a named preset here with CLAUDE_CONFIG_DIR:
#
# [work]
# CLAUDE_CONFIG_DIR=~/.claude-work

[kimi]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://api.kimi.com/coding/
ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-for-coding
ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-for-coding
ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-for-coding

[glm]
ANTHROPIC_AUTH_TOKEN=sk-xxxxxxxxxxxxxxxx
ANTHROPIC_BASE_URL=https://open.bigmodel.cn/api/anthropic/
ANTHROPIC_DEFAULT_SONNET_MODEL=glm-4.5
ANTHROPIC_DEFAULT_HAIKU_MODEL=glm-4.5-air
ANTHROPIC_DEFAULT_OPUS_MODEL=glm-4.5
'@

# ------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------
function Set-ProfileBlock {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ProfilePath) | Out-Null
    $lines = @()
    if (Test-Path -LiteralPath $ProfilePath) { $lines = @(Get-Content -LiteralPath $ProfilePath) }
    # Drop any existing clauder block, then re-append a fresh one.
    $out = @(); $skip = $false
    foreach ($l in $lines) {
        if ($l -eq $BeginMarker) { $skip = $true; continue }
        if ($l -eq $EndMarker)   { $skip = $false; continue }
        if (-not $skip) { $out += $l }
    }
    $out += $BeginMarker
    $out += ". `"$WrapperPath`""
    $out += $EndMarker
    Write-TextFile $ProfilePath ($out -join "`r`n")
}

function Remove-ProfileBlock {
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return }
    $out = @(); $skip = $false
    foreach ($l in @(Get-Content -LiteralPath $ProfilePath)) {
        if ($l -eq $BeginMarker) { $skip = $true; continue }
        if ($l -eq $EndMarker)   { $skip = $false; continue }
        if (-not $skip) { $out += $l }
    }
    Write-TextFile $ProfilePath ($out -join "`r`n")
}

function Invoke-Install {
    Write-Host "Step 1/3: Writing wrapper..." -ForegroundColor Green
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    Write-TextFile $WrapperPath $WrapperContent
    Write-Host "Step 2/3: Sourcing wrapper from your PowerShell profile..." -ForegroundColor Green
    Set-ProfileBlock
    Write-Host "Step 3/3: Writing sample config (if missing)..." -ForegroundColor Green
    if (Test-Path -LiteralPath $ConfPath) {
        Write-Host "Config already exists: $ConfPath (leaving it untouched)." -ForegroundColor Yellow
    } else {
        Write-TextFile $ConfPath $SampleConf
    }
    Write-Host "Installation complete." -ForegroundColor Green
    Write-Host "Next: open a new terminal (or run '. `$PROFILE'), then test 'claude --list'."
}

function Invoke-Status {
    Write-Host "Claude Wrapper Status (Windows)"
    Write-Host "-------------------------------"
    if (Test-Path -LiteralPath $WrapperPath) {
        Write-Host "Wrapper file: $WrapperPath" -ForegroundColor Green
    } else {
        Write-Host "Wrapper file: <not found> (expected at $WrapperPath)" -ForegroundColor Red
    }
    $sourced = (Test-Path -LiteralPath $ProfilePath) -and ((Get-Content -LiteralPath $ProfilePath) -contains $BeginMarker)
    if ($sourced) {
        Write-Host "Profile sourced: Yes ($ProfilePath)" -ForegroundColor Green
    } else {
        Write-Host "Profile sourced: No ($ProfilePath)" -ForegroundColor Red
    }
    if (Test-Path -LiteralPath $ConfPath) {
        $provs = (Select-String -LiteralPath $ConfPath -Pattern '^\[(.+)\]$').Matches.Groups |
            Where-Object { $_.Name -eq '1' } | ForEach-Object { $_.Value }
        Write-Host "Config file: $ConfPath" -ForegroundColor Green
        Write-Host ("Providers: {0}" -f ($provs -join ', ')) -ForegroundColor Yellow
    } else {
        Write-Host "Config file: <not found> (expected at $ConfPath)" -ForegroundColor Red
    }
}

function Invoke-Uninstall {
    $ans = Read-Host "Are you sure you want to uninstall the clauder wrapper? [y/N]"
    if ($ans -notmatch '^(y|Y|yes|YES)$') { Write-Host "Uninstall cancelled." -ForegroundColor Yellow; return }
    Remove-ProfileBlock
    if (Test-Path -LiteralPath $DataDir) { Remove-Item -Recurse -Force -LiteralPath $DataDir }
    Write-Host "Removed wrapper and profile hook." -ForegroundColor Green
    if ($Purge) {
        if (Test-Path -LiteralPath $ConfPath) {
            $ans2 = Read-Host "Also remove config $ConfPath? [y/N]"
            if ($ans2 -match '^(y|Y|yes|YES)$') { Remove-Item -Force -LiteralPath $ConfPath; Write-Host "Removed config." -ForegroundColor Green }
        }
    }
}

switch ($Command) {
    'install'   { Invoke-Install }
    'update'    {
        New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
        Write-TextFile $WrapperPath $WrapperContent
        Set-ProfileBlock
        Write-Host "Wrapper updated." -ForegroundColor Green
    }
    'uninstall' { Invoke-Uninstall }
    'status'    { Invoke-Status }
}
