# GitHub One-Click Init and Push (supports NEW and EXISTING repositories)
# Run from the root folder of the project you want to upload.
# Requires Git, GitHub CLI (gh), and an authenticated GitHub account.

$ErrorActionPreference = "Stop"

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($GitArgs -join ' ')"
    }
}

function Pause-And-Exit {
    param([int]$Code = 0)
    Write-Host ""
    Read-Host "Press Enter to close"
    exit $Code
}

try {
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "    GITHUB ONE-CLICK INIT, COMMIT & PUSH" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or is not available in PATH."
    }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI is not installed. Install it from https://cli.github.com/."
    }

    gh auth status 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not logged in. Run: gh auth login"
    }

    $account = (gh api user --jq .login).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($account)) {
        throw "Could not read your GitHub username."
    }

    Write-Host "GitHub account: $account" -ForegroundColor Green
    Write-Host "Project folder: $((Get-Location).Path)" -ForegroundColor Gray
    Write-Host ""

    # The only prompt
    $repoName = (Read-Host "Enter GitHub repository name").Trim()
    if ([string]::IsNullOrWhiteSpace($repoName)) {
        throw "Repository name cannot be empty."
    }
    if ($repoName -match '[/\\\s]' -or $repoName -match '[^A-Za-z0-9._-]') {
        throw "Enter only the repository name, using letters, numbers, dots, underscores or hyphens."
    }

    $repoFullName = "$account/$repoName"
    $repoUrl = "https://github.com/$repoFullName"
    $cloneUrl = "https://github.com/$repoFullName.git"

    # Find out whether the GitHub repository already exists.
    gh repo view $repoFullName 1>$null 2>$null
    $repoExists = ($LASTEXITCODE -eq 0)

    if ($repoExists) {
        Write-Host "Existing GitHub repository found. Will push to it." -ForegroundColor Yellow
    }
    else {
        Write-Host "Repository not found. A new private repository will be created." -ForegroundColor Yellow
    }

    # Check likely secrets before staging. Review .gitignore for other secrets too.
    $sensitiveFiles = Get-ChildItem -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git[\\/]' -and
            ($_.Name -eq ".env" -or $_.Name -like ".env.*" -or
             $_.Name -match '^(id_rsa|id_ed25519|.*\.pem|.*\.p12|.*\.pfx)$')
        }

    if ($sensitiveFiles) {
        Write-Host "Possible secret/private-key files found:" -ForegroundColor Yellow
        $sensitiveFiles | ForEach-Object { Write-Host "  $($_.FullName)" -ForegroundColor Yellow }
        throw "Stopped for safety. Add these files to .gitignore or move them outside the project, then run again."
    }

    # Initialize local Git repository if required.
    if (-not (Test-Path ".git")) {
        Invoke-Git init
    }

    Invoke-Git branch -M main

    # Point origin to the requested GitHub repository.
    $remotes = @(git remote)
    if ($LASTEXITCODE -ne 0) { throw "Could not read Git remotes." }

    if ($remotes -contains "origin") {
        Invoke-Git remote set-url origin $cloneUrl
    }
    else {
        Invoke-Git remote add origin $cloneUrl
    }

    # Stage and commit current project files.
    Invoke-Git add -A
    git diff --cached --quiet
    $diffExit = $LASTEXITCODE

    if ($diffExit -eq 1) {
        Invoke-Git commit -m "Update project"
    }
    elseif ($diffExit -ne 0) {
        throw "Could not inspect staged changes."
    }
    else {
        Write-Host "No new local changes to commit." -ForegroundColor Yellow
    }

    # Create repository if it did not exist.
    if (-not $repoExists) {
        gh repo create $repoFullName --private 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create the GitHub repository."
        }
    }

    # Fetch existing remote history before pushing.
    & git fetch origin
    if ($LASTEXITCODE -ne 0) {
        throw "Could not fetch the GitHub repository. Check network/access and try again."
    }

    # If remote main exists, merge it without discarding either side.
    $remoteMain = @(git ls-remote --heads origin main)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect the remote main branch."
    }

    if ($remoteMain.Count -gt 0) {
        Write-Host "Remote main branch exists. Combining remote history with local project..." -ForegroundColor Yellow
        & git merge origin/main --allow-unrelated-histories --no-edit
        if ($LASTEXITCODE -ne 0) {
            Write-Host "A merge conflict occurred. No force push was performed." -ForegroundColor Red
            Write-Host "Resolve conflicts, commit the merge, then run this script again."
            throw "Could not safely merge existing GitHub content."
        }
    }

    # Normal push only. Never force-push.
    Invoke-Git push -u origin main

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "          SUCCESS! PROJECT PUSHED" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "Repository: $repoUrl" -ForegroundColor Cyan
    Write-Host "Branch: main" -ForegroundColor Green
    Write-Host "Visibility: Existing setting preserved (new repositories are Private)." -ForegroundColor Gray
    Write-Host ""

    Start-Process $repoUrl
    Pause-And-Exit 0
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Pause-And-Exit 1
}
