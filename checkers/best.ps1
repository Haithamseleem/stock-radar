# Best Al-Yousifi (Kuwait): the shop's own SAP Commerce (OCC) product search, the one its web app calls.
# Store fields: occ (API base, public), site (base site id), site url in "url".
# The search is loose (any word), best matches first; the first 40 results are used.
function Find-best($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $f = [uri]::EscapeDataString('products(code,name,price(value,currencyIso),stock(stockLevelStatus),url,availableForPickup)')
    $json = Get-WebJson "$($Store.occ)/occ/v2/$($Store.site)/products/search?query=$q&pageSize=40&lang=en&curr=KWD&fields=$f"
    if ($null -eq $json.products -and $null -eq $json.pagination) { throw 'Best search returned an unexpected answer (blocked or changed?)' }
    foreach ($p in @($json.products)) {
        $status = "$($p.stock.stockLevelStatus)"
        $stock = $null
        if ($status -match '^(inStock|lowStock)$') { $stock = $true } elseif ($status) { $stock = $false }
        $note = if ($p.availableForPickup -eq $true) { 'Store pick-up offered' } else { '' }
        New-Listing $p.name $p.price.value $stock "$($Store.url.TrimEnd('/'))$($p.url)" -Note $note
    }
}
