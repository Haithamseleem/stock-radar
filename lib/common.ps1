# Shared helpers for the store checkers. Functions only: the runner loads every function in lib\ and checkers\
# into each parallel worker, so nothing outside a function body runs there.
#
# A checker lives in checkers\<adapter>.ps1 and defines   function Find-<adapter>($Store, $Product)
# It searches one store for one product and returns listings made with New-Listing (or Skip-Product when the
# product can't be looked up at that store). It does not decide what matches: the runner compares each listing's
# title with the product's include/exclude words and price floor, then works out the status.

function Get-UserAgent { 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36' }

# Body decoded as UTF-8 whatever the server claims (Windows PowerShell otherwise garbles Arabic and symbols).
function Get-Web([string]$Url, [hashtable]$Headers = @{}, [string]$Method = 'GET', $Body = $null, [string]$ContentType = '') {
    $h = @{ 'Accept-Language' = 'en-US,en;q=0.9' }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    $p = @{ Uri = $Url; UserAgent = (Get-UserAgent); UseBasicParsing = $true; TimeoutSec = 25; Headers = $h; Method = $Method }
    if ($null -ne $Body) { $p.Body = $Body }
    if ($ContentType) { $p.ContentType = $ContentType }
    $r = Invoke-WebRequest @p
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}

function Get-WebJson([string]$Url, [hashtable]$Headers = @{}, [string]$Method = 'GET', $Body = $null, [string]$ContentType = '') {
    $h = @{ Accept = 'application/json' }
    foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    Get-Web $Url $h $Method $Body $ContentType | ConvertFrom-Json
}

# curl.exe for stores that stall or block Windows PowerShell's own HTTP client; browser-style headers included.
# -Headers adds/overrides headers ('Name: value'); -Data sends a POST body; -Cookies keeps cookies across redirects.
function Get-Curl([string]$Url, [string[]]$Headers = @(), [string]$Data = $null, [switch]$Cookies) {
    $tmp = [IO.Path]::GetTempFileName()
    $jar = $null
    $extra = @()
    if ($Cookies) { $jar = [IO.Path]::GetTempFileName(); $extra += @('-b', $jar, '-c', $jar) }
    foreach ($h in $Headers) { $extra += @('-H', $h) }
    if ($Data) { $extra += @('--data-raw', $Data) }
    try {
        & curl.exe -s -L --compressed --max-time 25 -o $tmp -H "User-Agent: $(Get-UserAgent)" `
            -H 'Accept: text/html,application/json,*/*;q=0.8' -H 'Accept-Language: en-US,en;q=0.9' `
            -H 'Sec-Fetch-Mode: navigate' -H 'Sec-Fetch-Site: none' -H 'Sec-Fetch-Dest: document' -H 'Upgrade-Insecure-Requests: 1' @extra $Url
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE" }
        [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
        if ($jar) { Remove-Item $jar -ErrorAction SilentlyContinue }
    }
}

# The search words for this store: products.json "queries" can override "query" per adapter.
function Get-ProductQuery($Store, $Product) {
    if ($Product.queries -and $Product.queries.($Store.adapter)) { return $Product.queries.($Store.adapter) }
    $Product.query
}

# Lower case, "+" to " plus" (so "Galaxy S25+" isn't the S25), punctuation to spaces, "512 GB" -> "512gb", padded
# with spaces so terms match from a word start.
function ConvertTo-MatchText([string]$Text) {
    $t = ' ' + ($Text.ToLowerInvariant() -replace '\+', ' plus ' -replace '[^\p{L}\p{N}]+', ' ') + ' '
    $t = [regex]::Replace($t, '(\d+)\s+(gb|tb|mm|cm|hz|w|kg|l|ltr|btu)\b', '$1$2')
    $t -replace '\s+', ' '
}

# A product's include terms (each a list of alternatives, from "a|b") and exclude words in match form.
function Get-MatchTerms($Product) {
    [pscustomobject]@{
        Inc = @(foreach ($term in @($Product.include)) { , @(foreach ($alt in ("$term" -split '\|')) { $a = (ConvertTo-MatchText $alt).Trim(); if ($a) { $a } }) })
        Exc = @(foreach ($term in @($Product.exclude)) { $a = (ConvertTo-MatchText "$term").Trim(); if ($a) { $a } })
    }
}

# Every include term must appear from a word start, so "256" matches "256gb" (a term may list alternatives with |);
# no exclude word may appear. Uses the product's prepared "terms" when the run added them.
function Test-ProductMatch($Product, [string]$Title) {
    $t = ConvertTo-MatchText $Title
    $m = $Product.terms; if (-not $m) { $m = Get-MatchTerms $Product }
    foreach ($alts in $m.Inc) {
        $ok = $false
        foreach ($a in $alts) { if ($t.Contains(" $a")) { $ok = $true; break } }
        if (-not $ok) { return $false }
    }
    # Exclude words match whole words (plural too), so "stand" doesn't drop "standalone".
    foreach ($a in $m.Exc) { if ($t.Contains(" $a ") -or $t.Contains(" ${a}s ") -or $t.Contains(" ${a}es ")) { return $false } }
    $true
}

# "AED 9,349.00", 9349, "9349" -> 9349. Numbers pass through; text keeps the first number (thousands commas dropped).
function ConvertTo-Price($Value) {
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [ValueType]) { return [double]$Value }
    $m = [regex]::Match(("$Value" -replace '(?<=\d),(?=\d{3}\b)', ''), '\d+(?:\.\d+)?')
    if ($m.Success) { [double]$m.Value } else { $null }
}

# One product listing as the store shows it. InStock: $true, $false, or $null when the store doesn't say.
# City is set only for branch-level stock (e.g. pick-up at a store in that city); leave it empty for online stock.
# Coupon: the store's own coupon/promo text on that listing, e.g. "Save AED 100 with coupon" or "Extra 10% off with code NOON10".
# Image: a product photo URL from the store, when the result has one.
function New-Listing([string]$Title, $Price, $InStock, [string]$Url, [string]$Note = '', [string]$City = '', [switch]$PreOrder,
                     [string]$Coupon = '', [string]$Image = '') {
    @{ Title = $Title; Price = (ConvertTo-Price $Price); InStock = $InStock; Url = $Url; Note = $Note; City = $City; PreOrder = [bool]$PreOrder
       Coupon = $Coupon; Image = $Image }
}

# Returned by a checker when this product can't be looked up at this store (e.g. no part number for it).
function Skip-Product { @{ Skip = $true } }
