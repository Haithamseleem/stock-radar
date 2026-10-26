# Carrefour (Majid Al Futtaim sites): the search page is server-rendered and embeds every result as escaped JSON
# (stock.stockLevelStatus, productId, productName, sellingPrice, currency, productUrl, shopName). The site's own JSON
# APIs are behind Akamai bot checks, so we read the page with curl.exe (Get-Curl); Invoke-WebRequest gets an empty page.
# Store fields: site (host, e.g. www.carrefouruae.com), code (store id in the URL, e.g. mafuae), lbpPerUsd (Lebanon only:
# prices there are in LBP, the tracker uses USD).
function Find-carrefour($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $base = "https://$($Store.site)"
    $html = Get-Curl "$base/$($Store.code)/en/search?keyword=$q"
    if ($html -notmatch '<title>[^<]*Carrefour') { throw 'Carrefour search page not recognised (blocked?)' }
    $starts = [regex]::Matches($html, '\\"stock\\":\{\\"value\\":')
    if ($starts.Count -eq 0 -and $html -notmatch '__next_f') { throw 'Carrefour page has no product data (changed or blocked?)' }
    $seen = @{}
    for ($i = 0; $i -lt $starts.Count; $i++) {
        $from = $starts[$i].Index
        # A card's badges (promo code) sit up to ~23000 characters after its "stock" key; cards run up to ~27000 characters.
        $to = if ($i + 1 -lt $starts.Count) { $starts[$i + 1].Index } else { [Math]::Min($html.Length, $from + 27000) }
        $c = $html.Substring($from, $to - $from)
        $id    = [regex]::Match($c, '\\"productId\\":\\"(\d+)\\"').Groups[1].Value
        $name  = [regex]::Match($c, '\\"productName\\":\\"(.*?)\\",\\"').Groups[1].Value
        $price = [regex]::Match($c, '\\"sellingPrice\\":([\d.]+)').Groups[1].Value
        $path  = [regex]::Match($c, '\\"productUrl\\":\\"([^"\\]+)\\"').Groups[1].Value
        if (-not $id -or -not $name -or -not $price -or $seen[$id]) { continue }
        $seen[$id] = $true
        $name = [regex]::Replace($name, '\\+u([0-9a-fA-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
        $name = ($name -replace '\\+"', '"' -replace '\s+', ' ').Trim()
        $qty = [regex]::Match($c, '^\\"stock\\":\{\\"value\\":(\d+),').Groups[1].Value
        $lvl = [regex]::Match($c, '\\"stockLevelStatus\\":\\"(\w+)\\"').Groups[1].Value
        $inStock = ($lvl -notmatch 'outOfStock') -and ($qty -ne '0')
        $shop = [regex]::Match($c, '\\"shopName\\":\\"([^"\\]+)\\"').Groups[1].Value
        $note = if ($shop -and $shop -notmatch '^(carrefour|majid|maf)') { "Sold by $shop" } else { '' }
        $p = [double]$price
        if ($Store.lbpPerUsd) { $p = [Math]::Round($p / [double]$Store.lbpPerUsd, 2) }
        $url = if ($path) { "$base$path" } else { "$base/$($Store.code)/en/search?keyword=$q" }
        $img = [regex]::Match($c, '\\"imageUrl\\":\\"(https://[^"\\]+)\\"').Groups[1].Value
        # The green dashed promo-code badge, e.g. "Up to 100AED off | Code TECH100". The plain "3% OFF" badge is just the
        # markdown from the marked price, not a coupon, so only badges naming a code / coupon / promo are passed.
        $codes = @([regex]::Matches($c, '\\"primaryText\\":\\"([^"\\]*(?:[Cc]ode|[Cc]oupon|[Pp]romo)[^"\\]*)\\"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $coupon = [regex]::Replace(($codes -join '; '), '\\+u([0-9a-fA-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
        New-Listing $name $p $inStock $url -Note $note -Coupon $coupon -Image $img
    }
}
