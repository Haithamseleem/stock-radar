# SmartBuy Jordan (Shopify): the storefront's own predictive-search JSON (at most 10 products), out-of-stock ones included.
# Prices are in JOD with 3 decimals, e.g. "85.000".
function Find-smartbuy($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $base = $Store.url.TrimEnd('/')
    $json = Get-WebJson "$base/search/suggest.json?q=$q&resources%5Btype%5D=product&resources%5Blimit%5D=10&resources%5Boptions%5D%5Bunavailable_products%5D=last"
    if ($null -eq $json.resources) { throw 'SmartBuy search returned an unexpected answer' }
    foreach ($p in @($json.resources.results.products)) {
        $price = if ("$($p.price)" -match '^[\d.]+$') { [double]::Parse("$($p.price)", [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        New-Listing $p.title $price ([bool]$p.available) ($base + ($p.url -replace '\?.*$', ''))
    }
}
