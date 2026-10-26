# Jarir Bookstore (SA, KW, QA, AE, BH): search by the site's own search service (Constructor), then the site's
# own product API for stock (one request for up to 20 matching items).
# Store fields: key (Constructor search key of that country's English site, from the page source), site (e.g. sa-en),
# optional showrooms { "Riyadh": ["0114", ...] } = showroom codes per city: one pick-up listing per city, "in stock" when
# one of the city's showrooms is in the item's available_shr list.
function Get-JarirSearch($Store, [string]$Query) {
    $q = [uri]::EscapeDataString($Query)
    $json = Get-WebJson "https://ac.cnstrc.com/search/$q`?key=$($Store.key)&num_results_per_page=40"
    if ($null -eq $json.response) { throw 'Jarir search returned no response (blocked or key changed?)' }
    $results = @($json.response.results)
    # "...MagSafe Charging Case" is part of the earbuds, but products.json excludes the word "case" (phone cases).
    foreach ($r in $results) { $r.value = "$($r.value)" -replace '(?i)\b(magsafe\s+|wireless\s+)?charging\s+case\b', 'charging box' }
    $results
}

function Find-jarir($Store, $Product) {
    $query = Get-ProductQuery $Store $Product
    $results = @(Get-JarirSearch $Store $query)
    # The search needs every word ("256gb" is "256 GB" on the site): if nothing fits, try once without the last word.
    $words = @($query -split '\s+' | Where-Object { $_ })
    $fits = @($results | Where-Object { $_.data.sku -and (Test-ProductMatch $Product "$($_.value)") })
    if (-not $fits -and $words.Count -ge 3) {
        $more = @(Get-JarirSearch $Store (($words[0..($words.Count - 2)]) -join ' '))
        $fits = @($more | Where-Object { $_.data.sku -and (Test-ProductMatch $Product "$($_.value)") })
    }
    if (-not $fits) { return }

    # Stock and the current price come from the product API (the search result carries neither stock nor the discount).
    $docs = @{}
    $skus = @($fits | ForEach-Object { "$($_.data.sku)" } | Select-Object -Unique | Select-Object -First 40)
    for ($i = 0; $i -lt $skus.Count; $i += 20) {
        $chunk = @($skus[$i..([Math]::Min($i + 19, $skus.Count - 1))])
        $r = Get-WebJson "https://www.jarir.com/api/catalogv2/product/store/$($Store.site)/visibilityAll/true/sku/$($chunk -join ',')/size/$($chunk.Count)"
        if ($r.success -eq $false -or $null -eq $r.data) { throw 'Jarir product API returned no data' }
        foreach ($h in @($r.data.hits.hits)) { $docs["$($h._source.sku)"] = $h._source }
    }

    foreach ($hit in ($fits | Where-Object { $docs["$($_.data.sku)"] })) {
        $d = $docs["$($hit.data.sku)"]
        $price = $d.jarir_final_price
        if (-not $price) { $price = if ($d.special_price) { $d.special_price } else { $d.price } }
        $url = "https://www.jarir.com/$($Store.site)/$($hit.data.url)"
        $btn = "$($d.display_button)"
        $pre = ($btn -eq 'PREORDER' -or $btn -eq 'BACKORDER')
        $note = if ($btn -eq 'NOT_ONLINE') { 'Showroom only' } elseif ($btn -eq 'BACKORDER') { 'Backorder' } else { '' }
        $orderable = ($btn -ne 'SOLD_OUT' -and $btn -ne 'NO_BUTTON' -and $btn -ne 'NOT_ONLINE')
        $online = $orderable -and ($pre -or ("$($d.is_stock_available)" -in @('1', 'True')))
        New-Listing $hit.value $price $online $url -Note $note -PreOrder:$pre
        if ($Store.showrooms) {
            $have = @($d.available_shr | ForEach-Object { "$_" })
            foreach ($c in $Store.showrooms.PSObject.Properties) {
                $here = $false
                foreach ($code in @($c.Value)) { if ($have -contains "$code") { $here = $true } }
                New-Listing $hit.value $price ($here -and $btn -ne 'SOLD_OUT') $url -Note 'Showroom pick-up' -City $c.Name -PreOrder:$pre
            }
        }
    }
}
