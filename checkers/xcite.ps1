# Xcite by Alghanim (Kuwait): the site's own search endpoint (a proxy in front of its Algolia index).
# Store fields: index (e.g. xcite_prod_kw_en_relevancy). Only a few fields are requested: the full records contain
# keys that differ only by case, which Windows PowerShell's JSON reader rejects.
function Get-XciteHits($Store, [string]$Query) {
    $body = @{ operation = 'search'; requests = @(@{ indexName = $Store.index; query = $Query; hitsPerPage = 40
        attributesToRetrieve = @('name', 'slug', 'price', 'currency', 'inStock', 'status_key', 'clickAndCollectAvailable') }) } |
        ConvertTo-Json -Depth 5 -Compress
    $json = Get-WebJson 'https://www.xcite.com/api/algolia/proxy' @{} 'POST' $body 'application/json'
    if ($null -eq $json.results) { throw 'Xcite search returned no results object (blocked or changed?)' }
    @($json.results[0].hits)
}

function Find-xcite($Store, $Product) {
    $query = Get-ProductQuery $Store $Product
    $hits = @(Get-XciteHits $Store $query)
    # Every word must match: if nothing fits, try once without the last word ("... console", "... 256gb").
    $words = @($query -split '\s+' | Where-Object { $_ })
    $fits = @($hits | Where-Object { Test-ProductMatch $Product "$($_.name)" })
    if (-not $fits -and $words.Count -ge 3) {
        $seen = @{}; foreach ($h in $hits) { $seen["$($h.slug)"] = $true }
        $hits += @(Get-XciteHits $Store (($words[0..($words.Count - 2)]) -join ' ') | Where-Object { -not $seen["$($_.slug)"] })
    }
    foreach ($h in $hits) {
        $key = "$($h.status_key)"
        $pre = $key -match 'pre'
        $stock = ($key -eq 'InStock') -or ($pre -and $h.inStock -eq $true)
        $note = if ($h.clickAndCollectAvailable -eq $true) { 'Click & collect available' } else { '' }
        New-Listing $h.name $h.price $stock "https://www.xcite.com/$($h.slug)/p" -Note $note -PreOrder:$pre
    }
}
