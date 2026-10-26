# Lulu Hypermarket (Akinon storefront): /<locale>/list/?search_text= is server-rendered with each result as escaped JSON
# (pk, name, price, in_stock, currency_type, absolute_url, stock). Invoke-WebRequest gets 403, curl.exe (Get-Curl) works.
# Pre-orders are marked only in the product URL slug or name ("pre-order-...").
# Store fields: locale (URL prefix, e.g. en-ae).
function Find-lulu($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $base = "https://www.luluhypermarket.com/$($Store.locale)"
    $html = Get-Curl "$base/list/?search_text=$q&page_size=60"
    if ($html -notmatch 'akinoncloud') { throw 'Lulu page not recognised (blocked?)' }
    $starts = [regex]::Matches($html, '\\"pk\\":\\"(\d+)\\",\\"name\\":\\"(.*?)\\",\\"sku\\":')
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $from = $starts[$i].Index
        $to = if ($i + 1 -lt $starts.Count) { $starts[$i + 1].Index } else { [Math]::Min($html.Length, $from + 40000) }
        $c = $html.Substring($from, $to - $from)
        $t = [regex]::Match($c, '\\"price\\":\\"([\d.]+)\\",\\"in_stock\\":(\w+),')
        $u = [regex]::Match($c, '\\"absolute_url\\":\\"([^"\\]+)\\"').Groups[1].Value
        if (-not $t.Success -or -not $u) { continue }
        $name = $starts[$i].Groups[2].Value
        $name = [regex]::Replace($name, '\\+u([0-9a-fA-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
        $name = ($name -replace '\\+"', '"' -replace '\s+', ' ').Trim()
        $stockText = [regex]::Match($c, '\\"is_ready_to_basket\\":\w+,\\"stock\\":\\"([\d.]+)\\"').Groups[1].Value
        $qty = if ($stockText) { [double]$stockText } else { $null }
        $inStock = ($t.Groups[2].Value -eq 'true') -and ($null -eq $qty -or $qty -gt 0)
        $pre = ($u -match 'pre-?order') -or ($name -match 'pre-?order')
        # First product photo (productimage_set); Lulu's results carry no coupon or promo-code text (basket_offers was always empty).
        $img = [regex]::Match($c, '\\"productimage_set\\":\[\{[^\]]*?\\"image\\":\\"(https://[^"\\]+)\\"').Groups[1].Value
        New-Listing $name $t.Groups[1].Value $inStock "$base$u" -PreOrder:$pre -Image $img
    }
}
