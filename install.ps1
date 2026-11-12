# Leftovers installer for Windows.
#
#   irm https://raw.githubusercontent.com/muhammederem/claude-todo/main/install.ps1 | iex
#
# Installs the Python package from the latest release into its own virtual environment under
# %LOCALAPPDATA%\Leftovers, adds a Start menu shortcut and starts the app.
# Environment: $env:LEFTOVERS_VERSION = "v1.2.0" picks a release instead of the latest.
$ErrorActionPreference = "Stop"
$Repo = "muhammederem/claude-todo"

function Say($text) { Write-Host "==> $text" }
function Fail($text) { Write-Host "error: $text" -ForegroundColor Red; exit 1 }

$api = "https://api.github.com/repos/$Repo/releases"
$release = if ($env:LEFTOVERS_VERSION) { Invoke-RestMethod "$api/tags/$($env:LEFTOVERS_VERSION)" } else { Invoke-RestMethod "$api/latest" }
$tag = $release.tag_name
if (-not $tag) { Fail "could not read the release tag" }

# Python 3.9+: the py launcher first, then python on PATH (not the Microsoft Store stub)
$python = $null
foreach ($candidate in @(@("py", "-3"), @("python"))) {
    $exe = Get-Command $candidate[0] -ErrorAction SilentlyContinue
    if (-not $exe -or $exe.Source -like "*WindowsApps*") { continue }
    $extra = @($candidate | Select-Object -Skip 1)
    & $exe.Source @extra -c "import sys; sys.exit(sys.version_info < (3, 9))" 2>$null
    if ($LASTEXITCODE -eq 0) { $python = @($exe.Source) + $extra; break }
}
if (-not $python) { Fail "Python 3.9 or later is required: install it from https://www.python.org/downloads/ and run this again" }

$venv = Join-Path $env:LOCALAPPDATA "Leftovers\venv"
Say "Installing Leftovers $tag into $venv"
$pyArgs = @($python | Select-Object -Skip 1)
& $python[0] @pyArgs -m venv --clear $venv
if ($LASTEXITCODE -ne 0) { Fail "could not create a virtual environment" }
$py = Join-Path $venv "Scripts\python.exe"
& $py -m pip install --quiet --upgrade pip
# a source archive instead of git+https, so git is not needed
& $py -m pip install --quiet "leftovers[gui] @ https://github.com/$Repo/archive/refs/tags/$tag.zip#subdirectory=cli"
if ($LASTEXITCODE -ne 0) { Fail "pip could not install the package" }

$gui = Join-Path $venv "Scripts\leftovers-gui.exe"
$programs = [Environment]::GetFolderPath("Programs")
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut((Join-Path $programs "Leftovers.lnk"))
$link.TargetPath = $gui
$link.Description = "Unfinished work across your Claude Code sessions"
$link.Save()

Say "Done. Leftovers is in the Start menu and the notification area."
Start-Process $gui
