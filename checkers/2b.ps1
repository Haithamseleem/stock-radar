# 2B Egypt (Magento): the search page lists only products that can be added to the cart, so each result is
# in stock when it has an add-to-cart form. The price is the final (special) price.
function Find-2b($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $html = Get-Curl "$($Store.url.TrimEnd('/'))/catalogsearch/result/?q=$q"
    if ($html -notmatch '(?i)<title>\s*Search results') { throw '2B search page not recognised (blocked or changed?)' }
    foreach ($b in ($html -split '<li class="item product product-item')) {
        $end = $b.IndexOf('</li>'); if ($end -gt 0) { $b = $b.Substring(0, $end) }
        $m = [regex]::Match($b, 'class="product-item-link"\s+href="([^"]+)">\s*([^<]+?)\s*</a>')
        if (-not $m.Success) { continue }
        $p = [regex]::Match($b, 'data-price-amount="([\d.]+)"\s+data-price-type="finalPrice"')
        New-Listing ([Net.WebUtility]::HtmlDecode($m.Groups[2].Value)) $(if ($p.Success) { $p.Groups[1].Value } else { $null }) ($b -match 'tocart-form') $m.Groups[1].Value
    }
}
