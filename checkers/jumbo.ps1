# Jumbo: the storefront's own catalog search (Elasticsearch). Each product has a live stock flag; "Advance Payment" /
# virtual products are reservation listings rather than the item itself, so they are returned as pre-orders.
function Find-jumbo($Store, $Product) {
    $words = Get-ProductQuery $Store $Product
    $q = $words | ConvertTo-Json
    # All words but one must appear in the name (a "%" in the request makes the site's firewall answer "maintenance").
    $count = @($words -split '\s+' | Where-Object { $_ }).Count
    $need = if ($count -le 2) { $count } else { $count - 1 }
    $req = '{"query":{"bool":{"must":[{"match":{"name":{"query":' + $q + ',"minimum_should_match":' + $need + '}}}]}}}'
    $url = "$($Store.base)/api/catalog/magento_en/product/_search?size=50&_source_include=sku,name,url_path,final_price,stock,type_id,status,KeyProductFeatures&request=" +
        [uri]::EscapeDataString($req)
    $raw = Get-Curl $url
    if ($raw -notmatch '^\s*\{') { throw 'Jumbo answered with a web page instead of search results (maintenance or blocked?)' }
    $res = $raw | ConvertFrom-Json
    if ($null -eq $res.hits.hits) { throw 'Jumbo catalog search returned no results list (blocked or changed?)' }
    foreach ($hit in $res.hits.hits) {
        $s = $hit._source
        if ("$($s.status)" -ne '1') { continue }
        $note = ''
        $m = [regex]::Match("$($s.KeyProductFeatures)", 'Delivery Lead Time:\s*([^;]+)')
        if ($m.Success) { $note = 'Delivery ' + $m.Groups[1].Value.Trim() }
        $pre = ($s.name -match 'Advance Payment') -or ("$($s.type_id)" -eq 'virtual')
        New-Listing "$($s.name)" $s.final_price ([bool]$s.stock.is_in_stock) "$($Store.base)/$($s.url_path)" -Note $note -PreOrder:$pre
    }
}
