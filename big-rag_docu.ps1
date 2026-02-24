# ===========================================
# Lm Studio BIG-RAG DOCUMENTATION DONWLOADER
# ===========================================

$PATH = " "

$REPOS = @(
    " "
)

$ALLOWED_EXT = @( ".md",".markdown",".mdx",".txt",".pdf",".docx",".pptx",".xlsx",".json",".yaml",".yml",".toml",".htm",".html" )

# ===========================================

# --- HashSet O(1) per lookup estensioni ---
$ALLOWED_SET = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]$ALLOWED_EXT,
    [System.StringComparer]::OrdinalIgnoreCase
)

# --- Normalizza BASE_PATH ---
$BASE_PATH = [System.IO.Path]::GetFullPath($PATH)
if (-not (Test-Path $BASE_PATH)) {
    New-Item -ItemType Directory -Path $BASE_PATH -Force | Out-Null
    Write-Host "[INIT] Cartella base creata: $BASE_PATH" -ForegroundColor Cyan
}

# --- Verifica permessi di scrittura su BASE_PATH ---
function Assert-WritePermission {
    param([string]$FolderPath)
    $testFile = Join-Path $FolderPath ".write_test_$(New-Guid)"
    try {
        [System.IO.File]::WriteAllText($testFile, "")
        Remove-Item $testFile -Force
    } catch {
        Write-Error @"
[ERRORE PERMESSI] Lo script non ha accesso in scrittura su:
  $FolderPath

Possibili cause:
  - La cartella richiede privilegi elevati (esegui come Amministratore)
  - Le ACL di Windows negano la scrittura all'utente corrente: $env:USERDOMAIN\$env:USERNAME
  - Il percorso e' su un volume read-only o di rete con restrizioni

Azione richiesta: verificare le proprieta' -> Sicurezza della cartella oppure rieseguire con 'Run as Administrator'.
"@
        exit 1
    }
}

Assert-WritePermission -FolderPath $BASE_PATH

# --- Verifica dipendenze ---
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "[ERRORE] 'git' non trovato nel PATH di sistema."
    exit 1
}

# -----------------------------------------------
# SICUREZZA: nessuna operazione fuori da BASE_PATH
# -----------------------------------------------
function Assert-SafePath {
    param([string]$TargetPath)
    $resolved = [System.IO.Path]::GetFullPath($TargetPath)
    if (-not $resolved.StartsWith($BASE_PATH, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Error "[SICUREZZA] Percorso non consentito: $resolved"
        exit 1
    }
}

# -----------------------------------------------
# Normalizzazione URL canonica
# -----------------------------------------------
function Get-CanonicalGitUrl {
    param([string]$Url)
    $clean = $Url.TrimEnd('/').TrimEnd('.git')
    return "$clean.git"
}

# -----------------------------------------------
# Risoluzione dinamica branch predefinito
# -----------------------------------------------
function Get-DefaultBranch {
    param([string]$FolderPath)
    Assert-SafePath $FolderPath
    Push-Location $FolderPath
    try {
        $symref = git symbolic-ref refs/remotes/origin/HEAD 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($symref)) {
            git remote set-head origin --auto 2>&1 | Out-Null
            $symref = git symbolic-ref refs/remotes/origin/HEAD 2>$null
        }
        if (-not [string]::IsNullOrWhiteSpace($symref)) {
            return ($symref.Trim() -replace '^refs/remotes/origin/', '')
        }
        Write-Warning "[WARN] Branch predefinito non rilevabile, uso 'main' come fallback."
        return "main"
    } finally {
        Pop-Location
    }
}

# -----------------------------------------------
# Sparse-checkout via CLI + core.longpaths
# -----------------------------------------------
function Set-SparseCheckout {
    param([string]$FolderPath)
    Assert-SafePath $FolderPath
    Push-Location $FolderPath
    try {
        # Abilita path lunghi (>260 chars) — necessario su repo come dotnet/docs, dotnet/runtime
        git config core.longpaths true
        git sparse-checkout init --no-cone 2>&1 | Out-Null
        $patterns = $ALLOWED_EXT | ForEach-Object { "**/*$_" }
        git sparse-checkout set --no-cone $patterns 2>&1 | Write-Host
    } finally {
        Pop-Location
    }
}

# -----------------------------------------------
# Rimozione cartelle vuote con retry + backoff
# -----------------------------------------------
function Remove-EmptyFolders {
    param([string]$FolderPath)
    Assert-SafePath $FolderPath

    $gitDir = Join-Path $FolderPath ".git"
    $dirs = Get-ChildItem -Path $FolderPath -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch [regex]::Escape($gitDir) } |
        Sort-Object FullName -Descending

    foreach ($dir in $dirs) {
        Assert-SafePath $dir.FullName
        $isEmpty = -not (Get-ChildItem -Path $dir.FullName -Recurse -File -ErrorAction SilentlyContinue)
        if ($isEmpty) {
            $maxRetry = 4
            $wait     = 200
            for ($i = 0; $i -lt $maxRetry; $i++) {
                try {
                    Remove-Item -Path $dir.FullName -Force -Recurse -ErrorAction Stop
                    break
                } catch {
                    if ($i -eq ($maxRetry - 1)) {
                        Write-Warning "[WARN] Impossibile rimuovere (lock?): $($dir.FullName)"
                    } else {
                        Start-Sleep -Milliseconds $wait
                        $wait *= 2
                    }
                }
            }
        }
    }
}

# -----------------------------------------------
# LOOP PRINCIPALE
# -----------------------------------------------
foreach ($repoUrl in $REPOS) {

    $canonicalUrl  = Get-CanonicalGitUrl $repoUrl
    $repoName      = ($repoUrl.TrimEnd('/') -split '/')[-1]
    $repoOwner     = ($repoUrl.TrimEnd('/') -split '/')[-2]
    $repoDirName   = "$repoOwner`_$repoName"
    $repoLocalPath = Join-Path $BASE_PATH $repoDirName

    Assert-SafePath $repoLocalPath

    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Yellow
    Write-Host " REPO : $repoOwner/$repoName"             -ForegroundColor Yellow
    Write-Host " PATH : $repoLocalPath"                   -ForegroundColor Yellow
    Write-Host "=========================================" -ForegroundColor Yellow

    if (Test-Path (Join-Path $repoLocalPath ".git")) {

        Write-Host "[UPDATE] Aggiornamento..." -ForegroundColor Cyan
        $branch = Get-DefaultBranch -FolderPath $repoLocalPath
        Set-SparseCheckout -FolderPath $repoLocalPath
        Push-Location $repoLocalPath
        try {
            git fetch --all --prune 2>&1 | Write-Host
            git reset --hard "origin/$branch" 2>&1 | Write-Host
        } finally {
            Pop-Location
        }

    } else {

        if (Test-Path $repoLocalPath) {
            Assert-SafePath $repoLocalPath
            Remove-Item -Path $repoLocalPath -Recurse -Force
        }

        Write-Host "[CLONE] Clonazione con partial clone + sparse-checkout..." -ForegroundColor Green
        git clone --depth 1 --filter=blob:none --no-checkout $canonicalUrl $repoLocalPath 2>&1 | Write-Host

        if (Test-Path $repoLocalPath) {
            Assert-SafePath $repoLocalPath
            $branch = Get-DefaultBranch -FolderPath $repoLocalPath
            Set-SparseCheckout -FolderPath $repoLocalPath
            Push-Location $repoLocalPath
            try {
                git checkout $branch 2>&1 | Write-Host
            } finally {
                Pop-Location
            }
            Remove-EmptyFolders -FolderPath $repoLocalPath
        }
    }
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host " COMPLETATO"                               -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
