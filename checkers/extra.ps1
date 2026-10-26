# eXtra (Saudi Arabia, Bahrain, Oman): the site's own search service (Unbxd), same one its search page calls.
# Store fields: unbxdKey + unbxdSite (public keys from the site's page source), optional cityCodes
# { "Riyadh": "SA-riyadh", ... } to return one listing per city (the cities eXtra says the item is in stock for).

# The search service sends flags as the text "true"/"false" when fields are selected.
function Test-ExtraFlag($Value) { "$Value" -eq 'true' }

function Get-ExtraProducts($Store, [string]$Query) {
    $q = [uri]::EscapeDataString($Query)
    $f = 'nameEn,title,sellingPrice,price,currency,inStockFlag,available,preorder,comingSoon,productUrl,inStockCities,isMarketPlaceItem'
    $json = Get-WebJson "https://search.unbxd.io/$($Store.unbxdKey)/$($Store.unbxdSite)/search?q=$q&rows=60&fields=$f"
    if ($null -eq $json.response) { throw 'eXtra search returned no response (blocked or keys changed?)' }
    @($json.response.products)
}

function Find-extra($Store, $Product) {
    $query = Get-ProductQuery $Store $Product
    $items = @(Get-ExtraProducts $Store $query)
    # The search needs every word in the title ("... console" often isn't): if nothing fits, try once without the last word.
    $words = @($query -split '\s+' | Where-Object { $_ })
    $fits = @($items | Where-Object { Test-ProductMatch $Product "$($_.nameEn)$($_.title)" })
    if (-not $fits -and $words.Count -ge 3) {
        $more = @(Get-ExtraProducts $Store (($words[0..($words.Count - 2)]) -join ' '))
        $seen = @{}; foreach ($i in $items) { $seen["$($i.productUrl)"] = $true }
        $items += @($more | Where-Object { -not $seen["$($_.productUrl)"] })
    }
    foreach ($p in $items) {
        $title = if ($p.nameEn) { $p.nameEn } else { $p.title }
        $price = if ($p.sellingPrice) { $p.sellingPrice } else { $p.price }
        if (-not $price) { continue }   # placeholder pages ("Get ready for ...") carry no price
        $pre = (Test-ExtraFlag $p.preorder) -or (Test-ExtraFlag $p.comingSoon)
        $stock = Test-ExtraFlag $p.inStockFlag
        $note = if (Test-ExtraFlag $p.isMarketPlaceItem) { 'Marketplace seller' } else { '' }
        $url = "$($p.productUrl)"
        if (-not $url.StartsWith('http')) { $url = $Store.url }
        if ($Store.cityCodes) {
            $have = @("$($p.inStockCities)" -split '\s+' | Where-Object { $_ })
            foreach ($c in $Store.cityCodes.PSObject.Properties) {
                New-Listing $title $price ($stock -and ($have -contains $c.Value)) $url -Note $note -City $c.Name -PreOrder:$pre
            }
        } else {
            New-Listing $title $price $stock $url -Note $note -PreOrder:$pre
        }
    }
}
