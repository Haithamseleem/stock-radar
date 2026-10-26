# Virgin Megastore (Hybris): the server-rendered search page, sorted by highest price (so phones and consoles come before
# cases), lists up to 48 products with name, price and link but no stock. Likely matches (right words, above the price
# floor) get their page read for the schema.org availability, cheapest first, until one is in stock (at most 6 reads).
# Store fields: base (site root, no trailing slash), usdRate (copy of the country's rate, to apply the price floor early).
function Find-virgin($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $html = Get-Curl "$($Store.base)/en/search?text=$q&sorting=highest_price"
    if ($html -notmatch '<title>\s*Search\b') { throw 'Virgin search page not recognised (blocked or layout changed?)' }
    $items = @()
    foreach ($tile in ($html -split '<li class="product-list__item')) {
        $name = [regex]::Match($tile, '\bdata-name="([^"]+)"')
        $link = [regex]::Match($tile, 'href="(/en/[^"]+/p/\d+)"')
        if (-not $name.Success -or -not $link.Success) { continue }
        $price = [regex]::Match($tile, '\bdata-price="([\d.]+)"').Groups[1].Value
        $items += [pscustomobject]@{
            Title = [Net.WebUtility]::HtmlDecode($name.Groups[1].Value).Trim(); Price = ConvertTo-Price $price
            Url = $Store.base + $link.Groups[1].Value; Stock = $null; Pre = $false }
    }
    $floor = 0
    if ($Product.minUsd -and $Store.usdRate) { $floor = [double]$Product.minUsd * [double]$Store.usdRate }
    $cands = @($items | Where-Object { $_.Price -ge $floor -and (Test-ProductMatch $Product $_.Title) } | Sort-Object Price | Select-Object -First 6)
    foreach ($c in $cands) {
        $page = Get-Curl $c.Url
        $av = [regex]::Match($page, '"availability"\s*:\s*"https?://schema\.org/(\w+)"').Groups[1].Value
        switch -Regex ($av) {
            'InStock|LimitedAvailability|OnlineOnly' { $c.Stock = $true }
            'OutOfStock|SoldOut|Discontinued'        { $c.Stock = $false }
            'PreOrder|PreSale|BackOrder'             { $c.Stock = $true; $c.Pre = $true }
        }
        if ($c.Stock -and -not $c.Pre) { break }
    }
    foreach ($i in $items) { New-Listing $i.Title $i.Price $i.Stock $i.Url -PreOrder:$i.Pre }
}
