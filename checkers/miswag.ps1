# Miswag (Iraq marketplace): the site's own search API (the Typesense-backed /api/v1/search the web page calls).
# Prices are in IQD. The results don't say whether an item can be bought, so InStock is left unknown (shows as Unverified).
function Find-miswag($Store, $Product) {
    $body = @{ query = (Get-ProductQuery $Store $Product); activeFilters = @{}; page = 1; perPage = 30 } | ConvertTo-Json -Compress
    $json = Get-WebJson 'https://miswag.com/api/v1/search' @{ Origin = 'https://miswag.com'; Referer = 'https://miswag.com/search' } 'POST' $body 'application/json'
    if (-not $json.success -or $null -eq $json.data -or $null -eq $json.data.hits) { throw 'Miswag search returned an unexpected answer' }
    foreach ($h in $json.data.hits) {
        $title = if ($h.title.EN) { $h.title.EN } else { $h.title.AR }
        $note = if ($h.merchant) { "seller: $($h.merchant)" } else { '' }
        New-Listing $title $h.price.value $null $h.url -Note $note
    }
}
