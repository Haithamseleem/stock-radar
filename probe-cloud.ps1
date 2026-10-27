# Runs in GitHub Actions only (probe.yml): shows what each store sends GitHub's servers for one search, so a
# failing checker can be told apart as "layout changed" (fix the parser) or "blocked" (mark it cloud-blocked).
# It makes exactly the requests the checker makes, with the same headers; nothing is added to get past a block.
param([string]$Stores = $env:PROBE_STORES, [string]$Query = $env:PROBE_QUERY)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = $PSScriptRoot
foreach ($f in @(Get-ChildItem "$Root\lib\*.ps1") + @(Get-ChildItem "$Root\checkers\*.ps1")) { . $f.FullName }

# Same request as lib\common.ps1's Get-Curl, but it also keeps the status code, final address and body of each call.
$script:calls = New-Object Collections.ArrayList
function Get-Curl([string]$Url, [string[]]$Headers = @(), [string]$Data = $null, [switch]$Cookies) {
    $tmp = [IO.Path]::GetTempFileName(); $jar = $null; $extra = @()
    if ($Cookies) { $jar = [IO.Path]::GetTempFileName(); $extra += @('-b', $jar, '-c', $jar) }
    foreach ($h in $Headers) { $extra += @('-H', $h) }
    if ($Data) { $extra += @('--data-raw', $Data) }
    try {
        $w = & curl.exe -s -L --compressed --max-time 25 -o $tmp -w '%{http_code} %{time_total} %{url_effective}' -H "User-Agent: $(Get-UserAgent)" `
            -H 'Accept: text/html,application/json,*/*;q=0.8' -H 'Accept-Language: en-US,en;q=0.9' `
            -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-Dest: document' -H 'Upgrade-Insecure-Requests: 1' @extra $Url
        $code = $LASTEXITCODE
        $body = if (Test-Path $tmp) { [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8) } else { '' }
        [void]$script:calls.Add([pscustomobject]@{ Url = $Url; Curl = $code; Info = "$w"; Body = $body })
        if ($code -ne 0) { throw "curl failed with exit code $code" }
        $body
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        if ($jar) { Remove-Item $jar -ErrorAction SilentlyContinue }
    }
}

$all = Get-ChildItem "$Root\data\stores\*.json" | ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } }
$markers = 'captcha|access denied|akamai|incapsula|cf-chl|cloudflare|pardon our interruption|request unsuccessful|edgesuite|reference #|bot detection|are you a robot|perimeterx|px-captcha|datadome'
foreach ($id in ($Stores -split '[,\s]+' | Where-Object { $_ })) {
    $s = $all | Where-Object id -eq $id
    if (-not $s) { Write-Host "== ${id}: no such store"; continue }
    $script:calls.Clear()
    $p = [pscustomobject]@{ id = 'probe'; name = $Query; query = $Query; include = @(); exclude = @() }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $result = try { $l = @(& "Find-$($s.adapter)" $s $p); "OK: $($l.Count) listing(s)$(if ($l.Count) { ', first: ' + ($l[0].Title -replace '\s+', ' ').Substring(0, [Math]::Min(70, $l[0].Title.Length)) })" } catch { "FAILED: $($_.Exception.Message)" }
    Write-Host "== $id ($($s.adapter)) in $([int]$sw.Elapsed.TotalSeconds) s: $result"
    foreach ($c in $script:calls | Select-Object -First 3) {
        $title = [regex]::Match($c.Body, '<title[^>]*>([^<]{0,90})').Groups[1].Value.Trim()
        $hits = @([regex]::Matches($c.Body, $markers, 'IgnoreCase') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique)
        $text = ([regex]::Replace(([regex]::Replace($c.Body, '(?is)<(script|style)[^>]*>.*?</\1>', ' ')), '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
        Write-Host ("   GET {0}" -f $c.Url)
        Write-Host ("     curl exit {0}; status, seconds, final address: {1}; {2:N0} bytes" -f $c.Curl, $c.Info, $c.Body.Length)
        Write-Host ("     title: '{0}'; bot-check words: {1}" -f $title, $(if ($hits) { $hits -join ', ' } else { 'none' }))
        Write-Host ("     text: {0}" -f $text.Substring(0, [Math]::Min(220, $text.Length)))
    }
}
