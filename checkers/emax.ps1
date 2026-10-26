# Emax: the search page ships its result list (Algolia hits) inside the page state, but the hits' own inStock flag is always 1,
# so the real unit counts come from Emax's stock API (one batched call for the likely matches). A product page is read only
# to tell pre-orders from normal stock, cheapest first, until a normal in-stock one is found (at most 3 reads).
# Store fields: base, applicationId, tenantId (the site's API context), usdRate (copy of the country's rate, for the price floor).
function Find-emax($Store, $Product) {
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 100MB
    $html = Get-Curl "$($Store.base)/search?q=$([uri]::EscapeDataString((Get-ProductQuery $Store $Product)))"
    $b64 = [regex]::Match($html, '"initialState":"([A-Za-z0-9+/=]+)"').Groups[1].Value
    if (-not $b64) { throw 'Emax search page has no embedded state (blocked or layout changed?)' }
    try { $state = $ser.DeserializeObject([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))) } catch { throw 'Emax page state could not be read' }
    $init = $state['algoliaProductReducer']['init']
    if ($null -eq $init -or $null -eq $init['hits']) { throw 'Emax search page has no result list (layout changed?)' }

    $items = @()
    foreach ($h in @($init['hits'])) {
        if (-not $h['title'] -or -not $h['sku'] -or -not $h['url']) { continue }
        $items += [pscustomobject]@{ Title = "$($h['title'])"; Price = ConvertTo-Price $h['price']; Sku = "$($h['sku'])"
            Url = $Store.base + ("$($h['url'])" -replace ' ', '%20'); Stock = $null; Pre = $false; Units = $null }
    }
    $floor = 0
    if ($Product.minUsd -and $Store.usdRate) { $floor = [double]$Product.minUsd * [double]$Store.usdRate }
    $cands = @($items | Where-Object { $_.Price -ge $floor -and (Test-ProductMatch $Product $_.Title) } | Sort-Object Price | Select-Object -First 12)

    if ($cands) {
        # The header's JSON needs its quotes escaped to survive Windows PowerShell's native argument passing.
        $ctx = '{\"applicationId\":' + $Store.applicationId + ',\"tenantId\":\"' + $Store.tenantId + '\"}'
        $api = "$($Store.base)/api/inventory/shop-sku-inventory/stock-availability?skuFieldType=SKU_CODE&skuFieldReferences=" +
            [uri]::EscapeDataString((@($cands | ForEach-Object { $_.Sku } | Select-Object -Unique) -join ','))
        $raw = Get-Curl $api @('X-Context-Request: ' + $ctx, 'Accept: application/json')
        if ($raw -notmatch '^\s*\[') { throw 'Emax stock API did not answer with stock rows (API changed?)' }
        $rows = $raw | ConvertFrom-Json
        foreach ($c in $cands) {
            $c.Units = 0
            foreach ($r in @($rows)) { if ($r.skuRef.skuCode -eq $c.Sku) { $c.Units += [int]$r.stock } }
            if ($c.Units -le 0) { $c.Stock = $false }
        }
        $reads = 0
        foreach ($c in @($cands | Where-Object { $_.Units -gt 0 })) {
            if ($reads -ge 3) { break }
            $reads++
            $page = Get-Curl $c.Url
            $m = [regex]::Match($page, '"initialState":"([A-Za-z0-9+/=]+)"')
            if (-not $m.Success) { continue }
            $pdp = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))
            $c.Stock = $true
            if ($pdp -match '"preorder":true') { $c.Pre = $true } else { break }
        }
    }
    # No unit counts in the note: they change with every sale and would look like news.
    foreach ($i in $items) { New-Listing $i.Title $i.Price $i.Stock $i.Url -PreOrder:$i.Pre }
}
