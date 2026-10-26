# Sharaf DG (UAE, Oman, Bahrain): the site's public Algolia search. Each hit carries the online stock flag and the branch
# inventory (branch id -> in_stock / store_pickup), so city stock needs no second request.
# Store fields: index (Algolia index), branchCities (branch id or id prefix -> city name in countries.json), cities.
function Find-sharafdg($Store, $Product) {
    $appId = '9KHJLG93J1'
    $key = 'e81d5b30a712bb28f0f1d2a52fc92dd0'
    $params = 'hitsPerPage=50&attributesToRetrieve=post_title,price,in_stock,archive,post_status,permalink,main_sku,inventory,images&query=' +
        [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $res = Get-WebJson "https://$appId-dsn.algolia.net/1/indexes/$($Store.index)/query" @{ 'X-Algolia-Application-Id' = $appId; 'X-Algolia-API-Key' = $key } `
        'POST' (@{ params = $params } | ConvertTo-Json -Compress) 'application/json'
    if ($null -eq $res.hits) { throw 'Sharaf DG search returned no hit list (search key or index changed?)' }

    # branch id -> city, longest matching id prefix wins
    $map = @{}
    if ($Store.branchCities) { foreach ($p in $Store.branchCities.PSObject.Properties) { $map["$($p.Name)"] = "$($p.Value)" } }
    $cityOf = {
        param($id)
        $best = ''
        foreach ($k in $map.Keys) { if ("$id".StartsWith($k) -and $k.Length -gt $best.Length) { $best = $k } }
        if ($best) { $map[$best] } else { '' }
    }

    $listings = @()
    $withStock = @{}   # city -> $true when some matching, buyable listing has units there
    $firstOnline = $null
    foreach ($h in $res.hits) {
        $price = ConvertTo-Price $h.price
        $buyable = ("$($h.post_status)" -eq 'publish') -and ("$($h.archive)" -ne '1') -and $price -gt 0
        $pre = "$($h.post_title)" -match 'Pre-?order'
        $inStock = $buyable -and ("$($h.in_stock)" -eq '1')
        $url = "$($h.permalink)"
        # "images" is the 300x300 product photo. Hits carry no coupon text: their promo fields hold only free-gift items.
        $img = "$(@($h.images)[0])"
        if (-not $buyable) { $price = $null }
        $listings += New-Listing "$($h.post_title)" $price $inStock $url -PreOrder:$pre -Image $img
        # An archived or pre-order listing can still show branch units that are held for pre-orders, so only buyable ones count.
        if (-not ($buyable -and -not $pre -and $h.inventory)) { continue }
        if (-not $firstOnline -and (Test-ProductMatch $Product "$($h.post_title)")) { $firstOnline = @{ Title = "$($h.post_title)"; Price = $price; Url = $url; Image = $img } }
        $branches = @{}
        foreach ($b in $h.inventory.PSObject.Properties) {
            if ($b.Name -eq 'store_availability' -or $null -eq $b.Value) { continue }
            if ("$($b.Value.in_stock)" -ne '1' -or "$($b.Value.store_pickup)" -ne '1') { continue }
            $city = & $cityOf $b.Name
            if (-not $city) { continue }
            if (-not $branches.ContainsKey($city)) { $branches[$city] = @() }
            $branches[$city] += ("$($b.Value.name)" -replace '\s+', ' ').Trim()
        }
        foreach ($city in $branches.Keys) {
            if (Test-ProductMatch $Product "$($h.post_title)") { $withStock[$city] = $true }
            $listings += New-Listing "$($h.post_title)" $price $true $url -Note ('In store: ' + ($branches[$city] -join ', ')) -City $city -Image $img
        }
    }
    # Cities with branches but no units: say so, so the city shows as out of stock instead of unknown.
    if ($firstOnline) {
        foreach ($city in @($Store.cities)) {
            if ($city -and -not $withStock.ContainsKey($city)) {
                $listings += New-Listing $firstOnline.Title $firstOnline.Price $false $firstOnline.Url -City $city -Image $firstOnline.Image
            }
        }
    }
    $listings
}
