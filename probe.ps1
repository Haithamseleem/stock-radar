# For writing or fixing a checker: calls it directly and shows every listing the store returned, before matching.
#   probe.ps1 -Store noon-ae -Product ps5-pro        listings for a product, marked with whether they match it
#   probe.ps1 -Store noon-ae -Query "ps5 pro"        raw search with your own words
# (tracker.ps1 -Store noon-ae -Product ps5-pro shows the final status the page would get.)
param([Parameter(Mandatory = $true)][string]$Store, [string]$Product, [string]$Query, [int]$Show = 10)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Root = $PSScriptRoot
foreach ($f in @(Get-ChildItem "$Root\lib\*.ps1") + @(Get-ChildItem "$Root\checkers\*.ps1" -ErrorAction SilentlyContinue)) {
    $errs = $null; [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    if ($errs) { Write-Warning "Skipped $($f.Name): $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))" } else { . $f.FullName }
}
$s = Get-ChildItem "$Root\data\stores\*.json" | ForEach-Object { Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } } | Where-Object id -eq $Store
if (-not $s) { throw "No store with id '$Store' in data\stores\*.json" }
if ($Query) { $p = [pscustomobject]@{ id = 'probe'; name = $Query; query = $Query; include = @(); exclude = @() } }
else {
    $sections = (Get-Content "$Root\data\settings.json" -Raw -Encoding UTF8 | ConvertFrom-Json).sections
    $p = Expand-Catalog "$Root\data\catalog.json" $sections | Where-Object id -eq $Product
    if (-not $p) { throw "Give -Product <id from the expanded catalog, e.g. iphone-17-pro-max-256gb> or -Query <words>" }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$l = @(& "Find-$($s.adapter)" $s $p)
Write-Host "$($s.id): $($l.Count) listing(s) in $([int]$sw.Elapsed.TotalMilliseconds) ms for '$(Get-ProductQuery $s $p)'"
$l | Select-Object -First $Show | ForEach-Object {
    if ($_.Skip) { Write-Host '  (checker skipped this product)'; return }
    $m = if ($Query) { ' ' } elseif (Test-ProductMatch $p $_.Title) { '+' } else { '-' }
    $t = "$($_.Title)"; if ($t.Length -gt 80) { $t = $t.Substring(0, 80) + '...' }
    Write-Host ("  {0} stock={1,-5} pre={2,-5} price={3,-9} city={4,-10} {5}" -f $m, $_.InStock, $_.PreOrder, $_.Price, $_.City, $t)
}
if ($l.Count) { Write-Host "  first url: $($l[0].Url)" }
