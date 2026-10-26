# Publishes Stock Radar to your free GitHub account: GitHub Actions checks the stores around the clock and
# GitHub Pages hosts the page. Put a classic GitHub token (scopes: repo, workflow) and, for alerts, your Telegram
# bot token into local.json (never uploaded; both are encrypted for this Windows account on first use).
#   publish.ps1               upload changes and start a check
#   publish.ps1 -CopySecret   copy the Telegram bot token for the TELEGRAM_BOT_TOKEN secret and open its page
#   publish.ps1 -Test         send a test message to the Telegram channels from the cloud
#   publish.ps1 -Status       latest cloud runs and results
param([switch]$CopySecret, [switch]$Test, [switch]$Status)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root      = $PSScriptRoot
$localPath = Join-Path $Root 'local.json'
if (-not (Test-Path $localPath)) {
    [IO.File]::WriteAllText($localPath, "{`r`n  `"repo`": `"stock-radar`",`r`n  `"githubToken`": `"`",`r`n  `"telegramBotToken`": `"`"`r`n}`r`n")
    Write-Host "Created local.json: paste your GitHub token into githubToken, then run publish.ps1 again."
    return
}

# Plain tokens in local.json are replaced by DPAPI-encrypted copies that only this Windows account can read.
$local = Get-Content $localPath -Raw -Encoding UTF8 | ConvertFrom-Json
$changed = $false
foreach ($f in 'githubToken', 'telegramBotToken') {
    if ($local.$f) {
        $local | Add-Member -NotePropertyName "${f}Encrypted" -NotePropertyValue (ConvertTo-SecureString $local.$f -AsPlainText -Force | ConvertFrom-SecureString) -Force
        $local.$f = ''; $changed = $true
    }
}
if ($changed) { [IO.File]::WriteAllText($localPath, ($local | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) }
function Get-LocalSecret([string]$Field) {
    $c = $local."${Field}Encrypted"
    if (-not $c) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $c))
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

$token = Get-LocalSecret 'githubToken'
if (-not $token) { throw 'Paste a GitHub token (classic, scopes: repo + workflow) into githubToken in local.json first.' }
$headers = @{ Authorization = "token $token"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'stock-radar' }

function Invoke-GitHub([string]$Method, [string]$Path, $Body) {
    $p = @{ Method = $Method; Uri = "https://api.github.com$Path"; Headers = $headers; TimeoutSec = 60 }
    if ($null -ne $Body) { $p.ContentType = 'application/json; charset=utf-8'; $p.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 10 -Compress)) }
    Invoke-RestMethod @p
}
function Test-GitHub([string]$Path) {
    try { [void](Invoke-GitHub GET $Path); $true }
    catch { if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { $false } else { throw } }
}
# Git's own blob id, so unchanged files are not uploaded again.
function Get-BlobSha([byte[]]$Bytes) {
    $ms = New-Object IO.MemoryStream
    $hdr = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $ms.Write($hdr, 0, $hdr.Length); $ms.Write($Bytes, 0, $Bytes.Length)
    (([Security.Cryptography.SHA1]::Create().ComputeHash($ms.ToArray())) | ForEach-Object { $_.ToString('x2') }) -join ''
}

$owner = (Invoke-GitHub GET '/user').login
$name  = if ($local.repo) { $local.repo } else { 'stock-radar' }
$repo  = "/repos/$owner/$name"
$site  = "https://$($owner.ToLower()).github.io/$name/"

if ($CopySecret) {
    $bot = Get-LocalSecret 'telegramBotToken'
    if (-not $bot) { throw 'Paste your Telegram bot token into telegramBotToken in local.json first.' }
    Set-Clipboard -Value $bot
    Start-Process "https://github.com/$owner/$name/settings/secrets/actions/new"
    Write-Host 'Copied. On the page that opened: Name = TELEGRAM_BOT_TOKEN, paste into Secret, click Add secret.'
    return
}
if ($Status) {
    (Invoke-GitHub GET "$repo/actions/runs?per_page=5").workflow_runs |
        ForEach-Object { '{0:dd MMM HH:mm}  {1,-18} {2,-10} {3}' -f ([datetime]$_.created_at), $_.event, $_.status, $_.conclusion }
    try {
        $log = Invoke-RestMethod -Uri "https://api.github.com$repo/contents/tracker.log?ref=data" -Headers ($headers + @{ Accept = 'application/vnd.github.raw' }) -TimeoutSec 60
        "$log" -split "`n" | Where-Object { $_ } | Select-Object -Last 5
    } catch { Write-Host 'No cloud results yet.' }
    Write-Host "Page: $site"
    return
}
if ($Test) {
    Invoke-GitHub POST "$repo/actions/workflows/check.yml/dispatches" @{ ref = 'main'; inputs = @{ test = $true } } | Out-Null
    Write-Host 'Test message started; it arrives in about a minute.'
    return
}

# 1. Repository (public: Actions minutes and Pages are free for public repositories; secrets stay hidden).
if (-not (Test-GitHub $repo)) {
    Invoke-GitHub POST '/user/repos' @{ name = $name; description = 'Electronics in stock right now across the GCC and Arab countries'; private = $false; auto_init = $true; has_wiki = $false; homepage = $site } | Out-Null
    Start-Sleep -Seconds 3
    Write-Host "Created github.com/$owner/$name"
}
$branch = (Invoke-GitHub GET $repo).default_branch

# 2. Code and settings (never local.json or run results). Files removed here are removed there too.
$utf8 = New-Object Text.UTF8Encoding($false)
$readme = @"
# Stock Radar

**Live page:** $site

Which stores have the phone, console or gadget you want in stock right now, across the GCC and Arab countries.
Stores are checked automatically about every 15-20 minutes with GitHub Actions; pick your country, city and product on the page.

- Products: ``data/products.json`` (search words, words to ignore, price floor)
- Stores: ``data/stores/*.json``, one file per shopping platform; checkers in ``checkers/`` (see CHECKERS.md)
- Countries, cities and Telegram channels: ``data/countries.json``
"@
$files = [ordered]@{ 'README.md' = $utf8.GetBytes($readme) }
$managed = '^(lib|checkers|data|site|\.github)/|^(tracker|probe|publish)\.ps1$|^(CHECKERS|BRAND)\.md$'
Get-ChildItem $Root -Recurse -File | ForEach-Object {
    $rel = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
    if ($rel -match $managed -and $rel -notmatch '^site/data(-\w+)?\.js$') {
        # Link previews need the page's full address: {{SITE}} in the pages becomes it.
        $files[$rel] = if ($rel -match '^site/[^/]+\.html$') { $utf8.GetBytes([IO.File]::ReadAllText($_.FullName).Replace('{{SITE}}', $site)) } else { [IO.File]::ReadAllBytes($_.FullName) }
    }
}
$head  = (Invoke-GitHub GET "$repo/git/ref/heads/$branch").object.sha
$base  = (Invoke-GitHub GET "$repo/git/commits/$head").tree.sha
$known = @{}
(Invoke-GitHub GET "$repo/git/trees/$base`?recursive=1").tree | Where-Object { $_.type -eq 'blob' } | ForEach-Object { $known[$_.path] = $_.sha }
$entries = @(foreach ($path in $files.Keys) {
    if ($known[$path] -eq (Get-BlobSha $files[$path])) { continue }
    $blob = Invoke-GitHub POST "$repo/git/blobs" @{ content = [Convert]::ToBase64String($files[$path]); encoding = 'base64' }
    @{ path = $path; mode = '100644'; type = 'blob'; sha = $blob.sha }
})
$entries += @($known.Keys | Where-Object { $_ -match $managed -and -not $files.Contains($_) } | ForEach-Object { @{ path = $_; mode = '100644'; type = 'blob'; sha = $null } })
if ($entries) {
    $tree   = Invoke-GitHub POST "$repo/git/trees" @{ base_tree = $base; tree = $entries }
    $commit = Invoke-GitHub POST "$repo/git/commits" @{ message = 'Update Stock Radar'; tree = $tree.sha; parents = @($head) }
    Invoke-GitHub PATCH "$repo/git/refs/heads/$branch" @{ sha = $commit.sha } | Out-Null
    Write-Host "Uploaded $($entries.Count) change(s)."
} else { Write-Host 'Code is already up to date.' }

# 3. Pages, published by the workflow.
if (-not (Test-GitHub "$repo/pages")) { Invoke-GitHub POST "$repo/pages" @{ build_type = 'workflow' } | Out-Null; Write-Host 'GitHub Pages turned on.' }
if (-not (Test-GitHub "$repo/actions/secrets/TELEGRAM_BOT_TOKEN")) { Write-Host 'Telegram alerts are off until you run publish.ps1 -CopySecret (the page works without them).' }

# 4. Run a check now instead of waiting for the schedule (a just-uploaded workflow can take a few seconds to register).
foreach ($try in 1..6) {
    try { Invoke-GitHub POST "$repo/actions/workflows/check.yml/dispatches" @{ ref = $branch; inputs = @{ test = $false } } | Out-Null; break }
    catch { if ($try -eq 6) { throw }; Start-Sleep -Seconds 5 }
}
Write-Host "Check started. Page (live in about 5 minutes): $site"
