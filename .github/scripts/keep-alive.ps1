<#
    .SYNOPSIS
        Pousse un commit vide sur le depot pour empecher GitHub de desactiver
        le workflow planifie "Keep Supabase Ordonnance-Type Alive"
        (les runs planifies ne reinitialisent pas le compteur d'activite de 60 jours).

    .PARAMETER RepositoryPath
        Chemin du depot git. Par defaut : la racine du depot qui contient ce script.

    .PARAMETER RemoteName
        Nom du remote git a pousser. Par defaut : origin.

    .PARAMETER LogDirectory
        Dossier du fichier de log. Par defaut : %LOCALAPPDATA%\GitHubKeepAlive

    .PARAMETER DryRun
        Verifie l'etat du depot sans creer de commit ni pousser.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\.github\scripts\keep-alive.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string] $RepositoryPath,
    [string] $RemoteName = 'origin',
    [string] $LogDirectory = (Join-Path $env:LOCALAPPDATA 'GitHubKeepAlive'),
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

if (-not (Test-Path -LiteralPath $RepositoryPath)) {
    throw "Depot introuvable : $RepositoryPath"
}

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}
$LogFile = Join-Path $LogDirectory 'keep-alive.log'

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string] $Message,
        [string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string[]] $GitArguments
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git @GitArguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Log $line.Trim() 'GIT'
        }
    }

    if ($exitCode -ne 0) {
        throw "Echec de la commande 'git $($GitArguments -join ' ')' (code $exitCode)."
    }

    return $output
}

function Get-FirstLine {
    param(
        [Parameter(Mandatory = $true)][object[]] $Lines
    )

    return ($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
}

Push-Location -LiteralPath $RepositoryPath

try {
    Write-Log "Debut (depot : $RepositoryPath, dry run : $DryRun)"

    Invoke-Git -GitArguments @('rev-parse', '--is-inside-work-tree') | Out-Null

    $branch = Get-FirstLine -Lines (Invoke-Git -GitArguments @('rev-parse', '--abbrev-ref', 'HEAD'))
    if ($branch -eq 'HEAD') {
        throw 'HEAD detache : impossible de determiner la branche courante.'
    }
    Write-Log "Branche courante : $branch"

    Invoke-Git -GitArguments @('fetch', $RemoteName, '--prune', '--quiet') | Out-Null

    $remoteRef = "$RemoteName/$branch"
    $localSha = Get-FirstLine -Lines (Invoke-Git -GitArguments @('rev-parse', 'HEAD'))
    $remoteSha = Get-FirstLine -Lines (Invoke-Git -GitArguments @('rev-parse', $remoteRef))

    Write-Log "HEAD local  : $localSha"
    Write-Log "HEAD distant : $remoteSha ($remoteRef)"

    if ($localSha -ne $remoteSha) {
        Invoke-Git -GitArguments @('merge', '--ff-only', $remoteRef) | Out-Null
        Write-Log 'Mise a jour rapide depuis le depot distant effectuee.'
    }

    if ($DryRun) {
        Write-Log 'Dry run : aucun commit cree, rien n est pousse.'
        Write-Log 'Fin.'
        return
    }

    Invoke-Git -GitArguments @('commit', '--allow-empty', '-m', 'chore: scheduled keep-alive commit') | Out-Null
    $newSha = Get-FirstLine -Lines (Invoke-Git -GitArguments @('rev-parse', 'HEAD'))

    Invoke-Git -GitArguments @('push', $RemoteName, "HEAD:refs/heads/$branch") | Out-Null

    Write-Log "Commit keep-alive pousse : $newSha"
    Write-Log 'Fin.'
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
finally {
    Pop-Location
}