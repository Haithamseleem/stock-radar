# Microless: server-rendered search page (/search/?query=...). A card with a price is orderable; the cards
# of unavailable items show "Currently Unavailable" and no price. One site per country.
# Store fields: host (e.g. uae.microless.com).
function Find-microless($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $html = Get-Curl "https://$($Store.host)/search/?query=$q"
    if ($html -notmatch 'id="search-results-products"' -and $html -notmatch 'data-prodid="\d+"') {
        if ($html -match 'have not found any products') { return }
        throw 'Microless search page not recognised (blocked or layout changed?)'
    }
    $cards = [regex]::Split($html, '(?=<div data-prodid="\d+")') | Where-Object { $_ -match '^<div data-prodid="\d+"' }
    foreach ($c in $cards) {
        # The last card is followed by the page's JS templates (<% ... %>), which contain "Currently Unavailable" too.
        $c = ($c -split '<%|<div class="pagination')[0]
        $m = [regex]::Match($c, 'class="product-title">\s*<a href="([^"]+)"[^>]*>\s*([^<]+?)\s*</a>')
        if (-not $m.Success) { continue }
        $title = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value)
        $link = $m.Groups[1].Value
        if ($link -notmatch '^https://') { $link = "https://$($Store.host)" + $link }
        $price = [regex]::Match($c, 'price-amount[^>]*>\s*([\d,\.]+)').Groups[1].Value
        # The photo is lazy-loaded (data-src; src is a 1x1 placeholder). Cards show no coupon text, only a "39% OFF" markdown badge.
        $img = [regex]::Match($c, '<img[^>]*\sdata-src="(https://[^"]+)"').Groups[1].Value
        if ($price -and $c -notmatch 'product-unavailable') {
            $plain = [Net.WebUtility]::HtmlDecode(([regex]::Replace($c, '<[^>]+>', ' ') -replace '\s+', ' '))
            $by = [regex]::Match($plain, 'Delivered by\s+([A-Za-z]{3,9}\s+\d{1,2})').Groups[1].Value
            $note = if ($by) { "delivered by $by" } else { '' }
            New-Listing $title $price $true $link -Note $note -Image $img
        } else {
            New-Listing $title $null $false $link -Note 'Currently Unavailable' -Image $img
        }
    }
}
