# Stock Radar: checks every store in data\stores\*.json for every product in data\products.json, writes
# site\data.json for the web page, and posts a Telegram alert to the country's channel when something comes into stock.
#   tracker.ps1                                   full run (alerts only when a Telegram bot token is available)
#   tracker.ps1 -Store noon-ae -Product ps5-pro   test part of a run: prints results, saves nothing, sends nothing
#   tracker.ps1 -TestTelegram                     sends a test message to every Telegram channel in the settings
#   tracker.ps1 -Shard 0 -Shards 4                checks every 4th store only and saves results-0.json (cloud: one per machine)
#   tracker.ps1 -Merge                            combines results-*.json, then saves state, alerts and writes the page
#   tracker.ps1 -All                              checks every product now, ignoring the section schedules
#   tracker.ps1 -Country AE [-Section Phones]     check one country (and one section, all of it now); other results are kept
#   tracker.ps1 -Light ...                        for runs on this PC: 6 searches at a time, one per store, so the
#                                                 PC's connection (and the iPhone Duo tracker on it) isn't swamped
#   tracker.ps1 -PageOnly                         checks nothing: rewrites the page's data files from the catalog and
#                                                 the last results (e.g. after editing data\catalog.json)
#   tracker.ps1 -Light -Rotate                    checks the next country after the UAE in turn, only its 100 most
#                                                 overdue products (the PC's 2-hourly task)
param([string[]]$Store, [string[]]$Product, [switch]$NoAlerts, [switch]$Quiet, [switch]$TestTelegram,
      [int]$Shard = 0, [int]$Shards = 0, [switch]$Merge, [switch]$All, [switch]$Light, [string[]]$Country, [string]$Section,
      [switch]$PageOnly, [switch]$Rotate)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$scriptStart = Get-Date
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root        = $PSScriptRoot
$StatePath   = Join-Path $Root 'state.json'
$HistoryPath = Join-Path $Root 'history.json'
$HealthPath  = Join-Path $Root 'health.json'
$LogPath     = Join-Path $Root 'tracker.log'
$Partial     = [bool]($Store -or $Product) -and $Shards -eq 0 -and -not $Merge

function Write-Log([string]$Message) {
    # A log line is never worth failing a run over (test runs can write at the same moment).
    try {
        if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1MB) { Move-Item $LogPath "$LogPath.old" -Force }
        Add-Content -Path $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date).ToUniversalTime(), $Message) -Encoding UTF8
    } catch { }
}

# ConvertFrom-Json hands back a JSON array as one object; the ForEach-Object unrolls it.
function Read-Json([string]$Path) { Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } }

function Save-Json($Value, [string]$Path, [int]$Depth = 6) {
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth $Depth -Compress), (New-Object Text.UTF8Encoding($false)))
}

# Cloud: the TELEGRAM_BOT_TOKEN secret. This PC: local.json (never published), plain or DPAPI-encrypted by publish.ps1.
function Get-BotToken {
    if ($env:TELEGRAM_BOT_TOKEN) { return $env:TELEGRAM_BOT_TOKEN }
    $path = Join-Path $Root 'local.json'
    if (-not (Test-Path $path)) { return $null }
    $l = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($l.telegramBotToken) { return $l.telegramBotToken }
    if (-not $l.telegramBotTokenEncrypted) { return $null }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $l.telegramBotTokenEncrypted))
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Send-Telegram([string]$Token, [string]$Chat, [string]$Html, [string]$Url, [string]$Button = 'Buy now') {
    $msg = @{ chat_id = $Chat; text = $Html; parse_mode = 'HTML'; disable_web_page_preview = $true }
    if ($Url -match '^https?://') { $msg.reply_markup = @{ inline_keyboard = @(, @(@{ text = $Button; url = $Url })) } }
    $json = ConvertTo-Json -InputObject $msg -Depth 6 -Compress
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$Token/sendMessage" -TimeoutSec 20 `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
}

# Checkers and helpers: loaded here and, as function text, into every parallel worker.
# A checker file with a syntax error is left out (and logged) instead of stopping every store.
$asts = @{}
$files = @(@(Get-ChildItem (Join-Path $Root 'lib\*.ps1')) + @(Get-ChildItem (Join-Path $Root 'checkers\*.ps1') -ErrorAction SilentlyContinue) | Where-Object {
    $errs = $null; $asts[$_.FullName] = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    if ($errs) { Write-Log "Skipped $($_.Name): $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))"; Write-Warning "Skipped $($_.Name): $($errs[0].Message)" }
    -not $errs
})
foreach ($f in $files) { . $f.FullName }
$functionText = @(foreach ($f in $files) {
    $asts[$f.FullName].EndBlock.Statements |
        Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }
}) -join "`n"

$settings  = Get-Content (Join-Path $Root 'data\settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
# Countries with "active": false (and their stores) are kept in the files but left out of runs and the page.
$countries = @(Read-Json (Join-Path $Root 'data\countries.json') | Where-Object { $_.active -ne $false })
$countryBy = @{}; foreach ($c in $countries) { $countryBy[$c.code] = $c }
if ($TestTelegram) {
    $token = Get-BotToken
    if (-not $token) { throw 'No Telegram bot token: set the TELEGRAM_BOT_TOKEN secret (cloud) or telegramBotToken in local.json.' }
    $chs = @(@($countries | ForEach-Object { $_.telegram }) + $settings.globalChannel | Where-Object { $_ } | Select-Object -Unique)
    if (-not $chs) { Write-Host 'No channels yet: add "@channel" to countries.json "telegram" or settings.json "globalChannel".'; return }
    foreach ($ch in $chs) {
        try { Send-Telegram $token $ch "<b>Test: $($settings.title) alerts are working</b>`nThis channel gets a message the moment a product comes into stock." $null; Write-Host "Test sent to $ch" }
        catch { Write-Host "Test to $ch failed: $($_.Exception.Message)" }
    }
    return
}
$catalogPath = Join-Path $Root 'data\catalog.json'
$products  = if (Test-Path $catalogPath) { @(Expand-Catalog $catalogPath $settings.sections) } else { @(Read-Json (Join-Path $Root 'data\products.json') | Where-Object { -not $_.disabled }) }
$stores    = @(Get-ChildItem (Join-Path $Root 'data\stores\*.json') | ForEach-Object { Read-Json $_.FullName } | Where-Object { -not $_.disabled -and $countryBy.ContainsKey($_.country) })
if ($Store)   { $stores   = @($stores | Where-Object { $_.id -in $Store }) }
if ($Product) { $products = @($products | Where-Object { $_.id -in $Product }) }
# Match words prepared once per product: a run matches thousands of store titles against them.
foreach ($p in $products) { $p | Add-Member -NotePropertyName terms -NotePropertyValue (Get-MatchTerms $p) -Force }
$stores = @($stores | Where-Object {
    if (Get-Command "Find-$($_.adapter)" -CommandType Function -ErrorAction SilentlyContinue) { return $true }
    Write-Log "Skipped $($_.id): no checker named Find-$($_.adapter)"; $false
})
# Every store the page knows about; -Country (and the cloud's -Shard) only narrow down which ones are checked now.
$allStores = @($stores)
# -Rotate: the next country in turn, other than the UAE (it has its own 30-minute task). rotation.json remembers the
# last country whose results were saved, so a run that was skipped or stopped tries the same country again.
if ($Rotate) {
    $RotationPath = Join-Path $Root 'rotation.json'
    $order = @($allStores | Where-Object { $_.country -ne 'AE' } | ForEach-Object { $_.country } | Sort-Object -Unique)
    if (-not $order) { throw 'Nothing to rotate: no stores outside the UAE.' }
    $last = ''
    try { if (Test-Path $RotationPath) { $last = "$((Get-Content $RotationPath -Raw -Encoding UTF8 | ConvertFrom-Json).last)" } } catch { }
    $Country = @($order[([array]::IndexOf($order, $last) + 1) % $order.Count])
}
if ($Country) { $stores = @($stores | Where-Object { $_.country -in $Country }) }
# settings.json "cloudBlockedStores": stores that refuse GitHub's servers (checked with probe.yml on 27 Oct: Cloudflare or
# Akamai challenge pages, empty pages, or no answer). The cloud doesn't ask them at all; the page lists them as "can't
# be checked from the cloud" and drops their old prices instead of showing them as current.
$cloudBlocked = @($settings.cloudBlockedStores | Where-Object { $_ })
$cloudRun = $Shards -gt 0 -or $Merge
if ($cloudRun) { $stores = @($stores | Where-Object { $_.id -notin $cloudBlocked }) }
if ($Shards -gt 0) {
    # Sorted by id, so the stores of one slow platform (e.g. six Lulu sites) land on different machines.
    $sorted = @($stores | Sort-Object id)
    $stores = @(for ($i = $Shard; $i -lt $sorted.Count; $i += $Shards) { $sorted[$i] })
}
if ((-not $stores -or -not $products) -and -not $Merge) { throw 'Nothing to check: no matching stores or products.' }

# Each product is checked every N runs ("every": hot items 1, sections from settings.json). Each family gets a fixed
# turn within its N runs, so the work is spread evenly instead of everything falling due in the same run. The run
# number comes from the cloud (RADAR_SLOT = the workflow's run number, the same on every machine) or the clock here.
# schedule.json remembers the last check; anything overdue (e.g. runs were skipped) is checked anyway. A product never
# checked waits for its turn too, so adding hundreds to the catalog spreads them over the next runs instead of one
# run that can't finish. -All or -Product checks everything asked for.
$SchedulePath = Join-Path $Root 'schedule.json'
$lastChecked = @{}
if (Test-Path $SchedulePath) { (Get-Content $SchedulePath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $lastChecked[$_.Name] = ([datetime]$_.Value).ToUniversalTime() } }
# A run for one country keeps that country's own schedule ("<product>@EG"); the UAE also reads the older plain keys.
$oneCountry = if ($Country -and @($Country).Count -eq 1) { "$(@($Country)[0])" } else { '' }
$schedKey = { param($id) if ($oneCountry) { "$id@$oneCountry" } else { $id } }
$lastOf = { param($id) $v = $lastChecked[(& $schedKey $id)]; if (-not $v -and $oneCountry -eq 'AE') { $v = $lastChecked[$id] }; $v }
$interval = [Math]::Max(1, [int]$settings.intervalMinutes)
$nowUtc = (Get-Date).ToUniversalTime()
$slot = if ($env:RADAR_SLOT) { [int]$env:RADAR_SLOT } else { [int][Math]::Floor(($nowUtc - [datetime]'2026-01-01').TotalMinutes / $interval) }
$turn = { param($p) $n = 0; foreach ($ch in "$(if ($p.family) { $p.family } else { $p.id })".ToCharArray()) { $n += [int]$ch }; $n }
$due = @($products | Where-Object {
    $every = [Math]::Max(1, [int]$_.every); $last = & $lastOf $_.id
    $All -or $Product -or $every -le 1 -or (($slot + (& $turn $_)) % $every) -eq 0 -or
    ($last -and ($nowUtc - $last).TotalMinutes -ge ($every * $interval * 1.5)) })
# Runs on this PC (-Light) check at most settings.runBudget families (about 20 minutes for the slowest store), so the
# 30-minute UAE runs and the 2-hourly rotation fit between each other. The most overdue go first: hot items, then the
# longest wait measured in the section's own interval; never checked counts as 1.5 intervals (frequent sections
# first). A UAE run takes only what's due (0.9 absorbs a late start); a rotation run fills its budget.
$budget = if ($Light -and -not ($All -or $Product -or $Section)) { if ($settings.runBudget) { [int]$settings.runBudget } else { 80 } } else { 0 }
if ($budget) {
    $due = @($products | Group-Object { if ($_.family) { $_.family } else { $_.id } } | ForEach-Object {
        $p = $_.Group[0]; $every = [Math]::Max(1, [int]$p.every); $last = & $lastOf $p.id
        $score = if ($p.hot) { 1e12 } elseif (-not $last) { 1.5 + 1 / $every } else { ($nowUtc - $last).TotalMinutes / ($every * $interval) }
        if ($Rotate -or $score -ge 0.9) { [pscustomobject]@{ Score = $score; Members = $_.Group } }
    } | Sort-Object Score -Descending | Select-Object -First $budget | ForEach-Object { $_.Members })
}
if ($Section) { $due = @($products | Where-Object { $_.category -eq $Section }) }
$dueIds = @($due | ForEach-Object { $_.id })

# Checkers that only use the search words can share one search between the sizes of a family; the ones that look at
# other product details (part numbers, their own matching) search once per product.
$canShare = @{}
foreach ($a in @($stores | ForEach-Object { $_.adapter } | Select-Object -Unique)) {
    $body = (Get-Command "Find-$a").Definition -replace 'Get-ProductQuery\s+\$Store\s+\$Product', ''
    $canShare[$a] = $body -notmatch '\$Product\b'
}

# Each store's products are split between a few workers (settings.perStoreParallel); a worker checks its share one
# after another with a pause, so a store never gets more than that many requests at once.
# Results go into a shared list as they arrive, so a store that runs out of time still keeps what it finished.
$worker = {
    param($Store, $Products, $FunctionText, $DelayMs, $Sink, $Share)
    $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
    . ([scriptblock]::Create($FunctionText))
    $fn = "Find-$($Store.adapter)"
    $first = $true
    $cache = @{}
    foreach ($p in $Products) {
        $q = "$(Get-ProductQuery $Store $p)"
        if ($Share -and $cache.ContainsKey($q)) { [void]$Sink.Add(@{ Store = $Store.id; Product = $p.id; Ok = $true; Listings = $cache[$q]; Ms = 0 }); continue }
        if (-not $first) { Start-Sleep -Milliseconds $DelayMs }
        $first = $false
        $t0 = [DateTime]::UtcNow
        try {
            $l = @(& $fn $Store $p)
            if ($Share) { $cache[$q] = $l }
            [void]$Sink.Add(@{ Store = $Store.id; Product = $p.id; Ok = $true; Listings = $l; Ms = ([DateTime]::UtcNow - $t0).TotalMilliseconds })
        }
        catch { [void]$Sink.Add(@{ Store = $Store.id; Product = $p.id; Ok = $false; Error = $_.Exception.Message; Ms = ([DateTime]::UtcNow - $t0).TotalMilliseconds }) }
    }
}
$sink = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
# One run at a time on this PC (the 30-minute task and the page's Refresh button share state.json); a refresh waits.
if (-not $Partial -and $Shards -eq 0 -and -not $Merge) {
    $runLock = New-Object System.Threading.Mutex($false, 'Local\StockRadar')
    $waitFrom = Get-Date
    try { $gotLock = $runLock.WaitOne([TimeSpan]::FromMinutes(25)) } catch [System.Threading.AbandonedMutexException] { $gotLock = $true }
    if (-not $gotLock) { Write-Log 'Skipped: another check was still running.'; return }
    $lockWait = (Get-Date) - $waitFrom
}
$pool = [runspacefactory]::CreateRunspacePool(1, $(if ($Light) { 6 } else { [Math]::Max(1, [int]$settings.parallelWorkers) }))
$pool.Open()
$started = Get-Date
$perStore = if ($Light) { 1 } else { [Math]::Max(1, [int]$settings.perStoreParallel) }
$shares = foreach ($s in $stores) {
    $mine = @($due | Where-Object { -not $_.countries -or $s.country -in @($_.countries) })
    # Whole families go to one worker, so its sizes can reuse the family's search.
    $fams = @($mine | Group-Object { if ($_.family) { $_.family } else { $_.id } })
    # Each run starts the list at a different point, so a slow store (Amazon) that runs out of time doesn't always miss
    # the same products at the end of the catalog (on 27 Oct: the Accessories light bars).
    if ($fams.Count -gt 1) { $off = $slot % $fams.Count; if ($off) { $fams = @($fams[$off..($fams.Count - 1)]) + @($fams[0..($off - 1)]) } }
    $n = [Math]::Min($perStore, $fams.Count)
    for ($k = 0; $k -lt $n; $k++) { [pscustomobject]@{ Store = $s; Share = $k; Products = @(for ($i = $k; $i -lt $fams.Count; $i += $n) { $fams[$i].Group }) } }
}
if ($Merge -or $PageOnly) { $shares = @() }
if ($PageOnly) { $dueIds = @() }
# Every store's first share is queued before any second share, so no store waits for the whole run to start.
$jobs = foreach ($sh in ($shares | Sort-Object Share)) {
    $ps = [powershell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($worker).AddArgument($sh.Store).AddArgument($sh.Products).AddArgument($functionText).AddArgument([int]$settings.storeDelayMs).AddArgument($sink).AddArgument([bool]$canShare[$sh.Store.adapter])
    [pscustomobject]@{ Store = $sh.Store; Products = $sh.Products; PS = $ps; Handle = $ps.BeginInvoke() }
}
$storeIds = @($jobs | ForEach-Object { $_.Store.id } | Select-Object -Unique)
$limit = if ($Light) { 1500 } else { [int]$settings.runTimeoutSeconds }
# On this PC the time limit counts from the script's start (less any wait for another run), so with its saving step
# a run ends within the 30 minutes between UAE runs.
$deadline = if ($Light) { $scriptStart.AddSeconds($limit) + $(if ($lockWait) { $lockWait } else { [TimeSpan]::Zero }) } else { $started.AddSeconds($limit) }
$timedOut = $false
foreach ($j in $jobs) {
    $left = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
    if ($j.Handle.AsyncWaitHandle.WaitOne($left)) {
        try { [void]$j.PS.EndInvoke($j.Handle) } catch { Write-Log "Worker for $($j.Store.id) failed: $($_.Exception.Message)" }
        $j.PS.Dispose()
    } else { $timedOut = $true; try { [void]$j.PS.BeginStop($null, $null) } catch { } }
}
# Closing the pool would wait for abandoned workers; leave those to process exit.
if (-not $timedOut) { $pool.Close() }

$got = @{}
foreach ($r in @($sink.ToArray())) { $got["$($r.Store)|$($r.Product)"] = $r }
$rows = New-Object Collections.ArrayList
$storeErrors = @{}
$storeMs = @{}
foreach ($j in $jobs) {
    $s = $j.Store
    foreach ($p in $j.Products) {
        $r = $got["$($s.id)|$($p.id)"]
        if (-not $r) { $r = @{ Ok = $false; Error = "Timed out: no answer within $limit seconds" } }
        if ($r.Ms) { if (-not $storeMs[$s.id]) { $storeMs[$s.id] = New-Object Collections.ArrayList }; [void]$storeMs[$s.id].Add($r.Ms) }
        if ($r.Ok) {
            try { foreach ($row in @(Resolve-Rows $s $p $r.Listings $countryBy[$s.country])) { [void]$rows.Add($row) }; continue }
            catch { $r = @{ Ok = $false; Error = "Could not read the results: $($_.Exception.Message)" } }
        }
        $storeErrors[$s.id] = $r.Error
        Write-Log "ERROR $($s.id) / $($p.id): $($r.Error)"
        [void]$rows.Add([pscustomobject]@{ Key = "$($s.id)|$($p.id)|"; Store = $s.id; Product = $p.id; City = ''; Status = 'Error'
                                          Price = $null; Title = ''; Url = $s.url; Note = $r.Error; Matches = 0 })
    }
}
$elapsed = [int]((Get-Date) - $started).TotalSeconds
if ($storeMs.Count) {
    $slow = $storeMs.Keys | Sort-Object { -($storeMs[$_] | Measure-Object -Average).Average } | Select-Object -First 6 |
        ForEach-Object { '{0} {1:N1}s' -f $_, (($storeMs[$_] | Measure-Object -Average).Average / 1000) }
    Write-Log "Slowest stores (average per search): $($slow -join ', ')"
}

# Cloud machines each check a share of the stores and hand their rows to the -Merge step.
if ($Shards -gt 0) {
    Save-Json ([ordered]@{ shard = $Shard; elapsed = $elapsed; storeIds = $storeIds; due = $dueIds; storeErrors = $storeErrors; rows = @($rows) }) (Join-Path $Root "results-$Shard.json") 5
    Write-Host "Shard $Shard of $Shards`: $($storeIds.Count) stores, $($rows.Count) results in $elapsed s."
    return
}
if ($Merge) {
    $files = @(Get-ChildItem (Join-Path $Root 'results-*.json'))
    if (-not $files) { throw 'Nothing to merge: no results-*.json files.' }
    $dueIds = @()
    foreach ($f in $files) {
        $res = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($row in @($res.rows)) { [void]$rows.Add($row) }
        foreach ($prop in @($res.storeErrors.PSObject.Properties)) { $storeErrors[$prop.Name] = $prop.Value }
        $storeIds += @($res.storeIds)
        $dueIds = @($dueIds + @($res.due) | Select-Object -Unique)
        $elapsed = [Math]::Max($elapsed, [int]$res.elapsed)
    }
    Write-Log "Merged $($files.Count) result file(s): $($storeIds.Count) stores, $($rows.Count) results."
}

if ($Partial) {
    $rows | Sort-Object Store, Product, City | Format-Table Store, Product, City, Status, Price, Matches,
        @{ n = 'Title / note'; e = { $t = if ($_.Title) { $_.Title } else { $_.Note }; if ("$t".Length -gt 90) { "$t".Substring(0, 90) + '...' } else { $t } } } -AutoSize |
        Out-String -Width 220 | Write-Host
    Write-Host "Checked $($storeIds.Count) store(s) in $elapsed s. Test run: nothing saved or sent."
    return
}

# Compare with the last run: keep the last good result while a store fails, record changes, collect alerts.
# state.json is large (every store x product); .NET's reader is several times faster than ConvertFrom-Json and gives
# dictionaries straight away.
$previous = @{}
if (Test-Path $StatePath) {
    Add-Type -AssemblyName System.Web.Extensions
    $reader = New-Object Web.Script.Serialization.JavaScriptSerializer; $reader.MaxJsonLength = [int]::MaxValue
    # Older runs saved missing values as {} (PowerShell's empty result); they're read back as null.
    $loaded = $reader.DeserializeObject(([IO.File]::ReadAllText($StatePath) -replace '":\{\}', '":null'))
    if ($loaded) { foreach ($kv in $loaded.GetEnumerator()) { if ($kv.Value) { $previous[$kv.Key] = $kv.Value } } }
}
# Last results by store and product, so a failed check finds them without scanning every result.
$previousBy = @{}
foreach ($k in $previous.Keys) {
    $parts = $k.Split('|'); $pk = "$($parts[0])|$($parts[1])|"
    if (-not $previousBy[$pk]) { $previousBy[$pk] = New-Object Collections.ArrayList }
    [void]$previousBy[$pk].Add($k)
}
$firstRun = -not (Test-Path $StatePath)
$history  = New-Object Collections.ArrayList
if (Test-Path $HistoryPath) { foreach ($h in @(Read-Json $HistoryPath)) { [void]$history.Add($h) } }
$now    = (Get-Date).ToUniversalTime().ToString('o')
$state  = @{}
$alerts = New-Object Collections.ArrayList
$productBy = @{}; foreach ($p in $products) { $productBy[$p.id] = $p }
foreach ($row in $rows) {
    if ($row.Status -eq 'Error') {
        $prefix = "$($row.Store)|$($row.Product)|"
        $kept = @(if ($previousBy[$prefix]) { $previousBy[$prefix] })
        foreach ($k in $kept) { $state[$k] = $previous[$k]; $state[$k].stale = $true }
        if (-not $kept) { $state[$row.Key] = @{ store = $row.Store; product = $row.Product; city = ''; status = 'Error'; note = $row.Note; url = $row.Url; since = $now; checked = $now } }
        continue
    }
    $old = $previous[$row.Key]
    $state[$row.Key] = @{ store = $row.Store; product = $row.Product; city = $row.City; status = $row.Status; price = $row.Price
                          title = $row.Title; url = (Compress-Url $row.Url); note = $row.Note; coupon = $row.Coupon
                          couponPrice = $(if ($row.Coupon) { Get-CouponPrice $row.Price $row.Coupon } else { $null })
                          image = $(if ($productBy[$row.Product].group) { $row.Image } else { $null }); firstImage = $row.Image
                          since = $(if ($old -and $old.status -eq $row.Status -and $old.since) { $old.since } else { $now }); checked = $now }
    # Model lists ("Bosch dishwashers") change all the time; they're shown, not tracked for changes or alerts.
    if ($productBy[$row.Product].group) { continue }
    if ($old -and $old.status -ne $row.Status -and $old.status -ne 'Error') {
        [void]$history.Add([ordered]@{ time = $now; store = $row.Store; product = $row.Product; city = $row.City; from = $old.status; to = $row.Status; price = $row.Price })
    }
    # New in stock since last run. A store or product seen for the first time doesn't alert (avoids a flood when added).
    if ($row.Status -eq 'InStock' -and $old -and $old.status -ne 'InStock' -and -not $firstRun) { [void]$alerts.Add($row) }
}
# A store/product this run didn't report keeps its last result: as-is when it simply wasn't due on its schedule,
# marked stale when it was due (e.g. one cloud machine failed).
$seenPairs = @{}; foreach ($row in $rows) { $seenPairs["$($row.Store)|$($row.Product)"] = $true }
$liveStores = @{}; foreach ($s in $allStores) { $liveStores[$s.id] = $true }
$runStores = @{}; foreach ($s in $stores) { $runStores[$s.id] = $true }
$dueSet = @{}; foreach ($id in $dueIds) { $dueSet[$id] = $true }
foreach ($k in @($previous.Keys)) {
    $parts = $k.Split('|')
    if (-not $state.ContainsKey($k) -and -not $seenPairs["$($parts[0])|$($parts[1])"] -and $liveStores[$parts[0]] -and $productBy[$parts[1]]) {
        $state[$k] = $previous[$k]
        if ($dueSet[$parts[1]] -and $runStores[$parts[0]]) { $state[$k].stale = $true }
    }
}
if ($cloudRun -and $cloudBlocked) { foreach ($k in @($state.Keys)) { if ($k.Split('|')[0] -in $cloudBlocked) { $state.Remove($k) } } }
Save-Json $state $StatePath
if ($Rotate) { Save-Json ([ordered]@{ last = $Country[0]; at = $now }) $RotationPath }
# A product counts as checked unless every store that tried it failed, so a run that timed out leaves those due
# (one no store could look up, e.g. skipped everywhere, still counts, so it doesn't stay due forever).
$answered = @{}; $failed = @{}
foreach ($row in $rows) { if ($row.Status -eq 'Error') { $failed[$row.Product] = $true } else { $answered[$row.Product] = $true } }
foreach ($id in $dueIds) { if ($answered[$id] -or -not $failed[$id]) { $lastChecked[(& $schedKey $id)] = $nowUtc } }
$sched = [ordered]@{}; foreach ($k in ($lastChecked.Keys | Sort-Object)) { if ($productBy[($k -split '@')[0]]) { $sched[$k] = $lastChecked[$k].ToString('o') } }
Save-Json $sched $SchedulePath
Save-Json @($history | Select-Object -Last 300) $HistoryPath 4

# Stores failing every product in a row are shown on the page as "couldn't check".
$health = @{}
if (Test-Path $HealthPath) { foreach ($prop in (Get-Content $HealthPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties) { $health[$prop.Name] = @{ fails = [int]$prop.Value.fails; since = $prop.Value.since; error = $prop.Value.error } } }
$storeAnswered = @{}; foreach ($row in $rows) { if ($row.Status -ne 'Error') { $storeAnswered[$row.Store] = $true } }
foreach ($id in $storeIds) {
    if (-not $storeAnswered[$id]) {
        if (-not $health[$id]) { $health[$id] = @{ fails = 0; since = $now; error = '' } }
        $health[$id].fails++; $health[$id].error = $storeErrors[$id]
    } else { $health.Remove($id) }
}
# A cloud-blocked store isn't failing: it isn't asked.
if ($cloudRun) { foreach ($id in $cloudBlocked) { $health.Remove($id) } }
Save-Json $health $HealthPath

# Telegram: each country's channel (countries.json "telegram") plus the optional all-countries channel (settings.globalChannel).
$token = if ($NoAlerts) { $null } else { Get-BotToken }
$sent = 0
if ($token -and $alerts.Count) {
    $storeBy = @{}; foreach ($s in $allStores) { $storeBy[$s.id] = $s }
    $productBy = @{}; foreach ($p in $products) { $productBy[$p.id] = $p }
    $byChannel = @{}
    foreach ($a in $alerts) {
        $country = $countryBy[$storeBy[$a.Store].country]
        foreach ($ch in @($country.telegram, $settings.globalChannel) | Where-Object { $_ } | Select-Object -Unique) {
            if (-not $byChannel[$ch]) { $byChannel[$ch] = New-Object Collections.ArrayList }
            [void]$byChannel[$ch].Add($a)
        }
    }
    $enc = { param($t) [Net.WebUtility]::HtmlEncode("$t") }
    foreach ($ch in $byChannel.Keys) {
        $list = @($byChannel[$ch]); $max = [Math]::Max(1, [int]$settings.maxAlertsPerChannel)
        foreach ($a in ($list | Select-Object -First $max)) {
            $s = $storeBy[$a.Store]; $c = $countryBy[$s.country]
            $lines = @("<b>In stock: $(& $enc $productBy[$a.Product].name)</b>",
                       "$(& $enc $s.name) $([char]0xB7) $(if ($a.City) { & $enc $a.City } else { 'Online' }) $([char]0xB7) $(& $enc $c.name)")
            if ($a.Price) { $lines += "<b>$($c.currency) $('{0:N0}' -f [double]$a.Price)</b>" }
            if ($a.Title) { $lines += "<i>$(& $enc ($(if ($a.Title.Length -gt 120) { $a.Title.Substring(0, 120) + '...' } else { $a.Title })))</i>" }
            if ($a.Note) { $lines += (& $enc $a.Note) }
            try { Send-Telegram $token $ch ($lines -join "`n") $a.Url; $sent++ } catch { Write-Log "Telegram to $ch failed: $($_.Exception.Message)" }
        }
        if ($list.Count -gt $max) {
            try { Send-Telegram $token $ch "<b>...and $($list.Count - $max) more just came into stock.</b> See the page for all of them." $null; $sent++ } catch { }
        }
    }
}

# The web page reads site\data.js (short keys keep it small: s store, p product, c city, st status, pr price, t title, u link, n note).
$site = Join-Path $Root 'site'
if (-not (Test-Path $site)) { New-Item -ItemType Directory $site | Out-Null }
# One logo per platform from fetch-logos.ps1 (site\logos\<adapter>.*); stores' "search" is a link template with {q}.
$logoFor = @{}
Get-ChildItem (Join-Path $site 'logos') -File -ErrorAction SilentlyContinue | ForEach-Object { $logoFor[$_.BaseName] = "logos/$($_.Name)" }
$photoFor = @{}
Get-ChildItem (Join-Path $site 'photos') -File -ErrorAction SilentlyContinue | ForEach-Object { $photoFor[$_.BaseName] = "photos/$($_.Name)" }
$searchLinks = @{}
$slPath = Join-Path $Root 'data\search-links.json'
if (Test-Path $slPath) { (Get-Content $slPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $searchLinks[$_.Name] = $_.Value } }
function Get-SearchLink($s) {
    if ($s.search) { return $s.search }
    $t = $searchLinks[$s.adapter]
    if (-not $t) { return $null }
    [regex]::Replace($t, '\{(\w+)\}', [Text.RegularExpressions.MatchEvaluator] { param($m) if ($m.Groups[1].Value -eq 'q') { '{q}' } else { "$($s.($m.Groups[1].Value))" } })
}
$storeCountry = @{}; foreach ($s in $allStores) { $storeCountry[$s.id] = $s.country }
# Product photo: fetch-photos.ps1's file for the product or its family, else the first store image seen for it.
$firstImage = @{}
foreach ($v in $state.Values) { if ($v.firstImage -and -not $firstImage[$v.product]) { $firstImage[$v.product] = $v.firstImage } }
$photo = { param($p) if ($photoFor[$p.id]) { $photoFor[$p.id] } elseif ($photoFor[$p.family]) { $photoFor[$p.family] } else { $firstImage[$p.id] } }
# Cheapest confirmed offer per product and country, for "cheapest in other countries" without loading every country.
$best = @{}
foreach ($v in $state.Values) {
    if ($v.status -ne 'InStock' -or $null -eq $v.price) { continue }
    $k = "$($v.product)|$($storeCountry[$v.store])"
    if (-not $best[$k] -or $v.price -lt $best[$k].pr) { $best[$k] = [ordered]@{ p = $v.product; c = $storeCountry[$v.store]; s = $v.store; pr = $v.price; u = $v.url; t = $v.title } }
}
$discounts = $null
$dPath = Join-Path $Root 'data\discounts.json'
if (Test-Path $dPath) { $discounts = Get-Content $dPath -Raw -Encoding UTF8 | ConvertFrom-Json }
# Countries with no store we can check are left off the page.
$data = [ordered]@{
    title           = $settings.title
    # A page-only rebuild keeps the time of the last real check.
    generatedAt     = $(if ($PageOnly -and (Test-Path (Join-Path $site 'data.js')) -and
                           ([IO.File]::ReadAllText((Join-Path $site 'data.js')) -match '"generatedAt":"([^"]+)"')) { $Matches[1] } else { $now })
    intervalMinutes = $settings.intervalMinutes
    rotateHours     = $settings.rotateHours
    requestUrl      = $settings.requestUrl
    globalChannel   = $settings.globalChannel
    countries       = @($countries | Where-Object { $storeCountry.Values -contains $_.code } | ForEach-Object {
                        [ordered]@{ code = $_.code; name = $_.name; currency = $_.currency; usdRate = $_.usdRate; cities = @($_.cities); telegram = $_.telegram } })
    stores          = @($allStores | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; adapter = $_.adapter; country = $_.country; url = $_.url; search = (Get-SearchLink $_)
                                                           logo = $logoFor[$_.adapter]; cities = @($_.cities | Where-Object { $_ }); weak = [bool]$_.weak
                                                           cloudBlocked = [bool]($cloudRun -and $_.id -in $cloudBlocked) } })
    products        = @($products | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; brand = $_.brand; category = $_.category; type = $_.type; family = $_.family
                                                               familyName = $_.familyName; size = $_.size; group = [bool]$_.group; hot = [bool]$_.hot; every = $_.every; query = $_.query; queries = $_.queries; photo = (& $photo $_) } })
    sections        = @($settings.sections)
    best            = @($best.Values)
    discounts       = $discounts
    problems        = @($health.Keys | Where-Object { $health[$_].fails -ge 2 } | ForEach-Object { [ordered]@{ s = $_; fails = $health[$_].fails; since = $health[$_].since; error = $health[$_].error } })
}
# Loaded as scripts (not fetched) so the pages also work opened straight from disk; store text can't close the tag.
# data.js has everything but the results; data-<country>.js has that country's results, so a page loads one country.
$toJs = { param($Value) (ConvertTo-Json -InputObject $Value -Depth 6 -Compress) -replace '</', '<\/' }
$utf8 = New-Object Text.UTF8Encoding($false)
# Written beside the old file and swapped in, so a page loading meanwhile gets the old or the new one, never half.
function Write-SiteFile([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text, $utf8)
    try { if (Test-Path $Path) { [IO.File]::Replace($tmp, $Path, $null) } else { [IO.File]::Move($tmp, $Path) } }
    catch { [IO.File]::WriteAllText($Path, $Text, $utf8); Remove-Item $tmp -ErrorAction SilentlyContinue }
}
Write-SiteFile (Join-Path $site 'data.js') ('window.RADAR_DATA = ' + (& $toJs $data) + ';')
# One pass over the results, sorted out by country. The page only shows what can be bought: full details for
# available offers; out-of-stock stores are kept as a bare marker (so "search it yourself" can leave them out);
# "not listed" and failed checks aren't needed. "updated" is when the country's stores were last checked (other
# countries are checked in turn, hours apart); failed checks don't count.
$rowsOf = @{}; $updatedOf = @{}
foreach ($v in $state.Values) {
    $code = $storeCountry[$v.store]
    if (-not $code) { continue }
    if ($v.checked -and $v.status -ne 'Error' -and "$($v.checked)" -gt "$($updatedOf[$code])") { $updatedOf[$code] = "$($v.checked)" }
    if ($v.status -notin 'InStock', 'Unverified', 'OutOfStock') { continue }
    if (-not $rowsOf[$code]) { $rowsOf[$code] = New-Object Collections.ArrayList }
    if ($v.status -eq 'OutOfStock') { [void]$rowsOf[$code].Add([ordered]@{ s = $v.store; p = $v.product; c = $v.city; st = 'OutOfStock' }); continue }
    $t = "$($v.title)"; if ($t.Length -gt 110) { $t = $t.Substring(0, 110).TrimEnd() + '...' }
    $r = [ordered]@{ s = $v.store; p = $v.product; c = $v.city; st = $v.status; pr = $v.price; t = $t; u = $v.url; since = $v.since }
    if ($v.note) { $r.n = $v.note }
    if ($v.stale) { $r.stale = $true }
    if ($v.coupon) { $r.cp = $v.coupon; $r.cpr = $v.couponPrice }
    if ($v.image) { $r.im = $v.image }
    [void]$rowsOf[$code].Add($r)
}
$written = @{}
foreach ($c in $data.countries) {
    $code = $c.code
    $mine = [ordered]@{
        rows    = @(if ($rowsOf[$code]) { $rowsOf[$code] })
        history = @($history | Where-Object { $storeCountry[$_.store] -eq $code } | Select-Object -Last 60)
        updated = $updatedOf[$code]
    }
    Write-SiteFile (Join-Path $site "data-$code.js") ("(window.RADAR_ROWS = window.RADAR_ROWS || {})['$code'] = " + (& $toJs $mine) + ';')
    $written["data-$code.js"] = $true
}
# A country no longer on the page loses its file only after the others are written.
Get-ChildItem $site -Filter 'data-*.js' | Where-Object { -not $written[$_.Name] } | Remove-Item -ErrorAction SilentlyContinue

$counts = ($rows | Group-Object Status | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
Write-Log "Run complete in $elapsed s ($([int]((Get-Date) - $scriptStart).TotalSeconds) s from start): $($storeIds.Count) stores, $counts, alerts sent=$sent"
if (-not $Quiet) {
    Write-Host "Checked $($storeIds.Count) stores x $($products.Count) products in $elapsed s: $counts. Alerts sent: $sent."
    $rows | Where-Object Status -eq 'InStock' | Sort-Object Product, Store | Format-Table Product, Store, City, Price, Title -AutoSize | Out-String -Width 220 | Write-Host
}
