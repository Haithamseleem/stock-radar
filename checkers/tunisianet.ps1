# Tunisianet (PrestaShop): the search page lists products with an "En stock" or "Sur commande" (on order) label.
# Prices read "1 299,000 DT" (space for thousands, comma for the 3 decimals), so they are turned into a number here.
function ConvertFrom-TunisianetPrice([string]$Text) {
    $t = ([Net.WebUtility]::HtmlDecode($Text) -replace '[^\d,.]', '') -replace ',', '.'
    if ($t -match '^\d+(\.\d+)?$') { [double]::Parse($t, [Globalization.CultureInfo]::InvariantCulture) } else { $null }
}

function Find-tunisianet($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $html = Get-Web "https://www.tunisianet.com.tn/recherche?controller=search&s=$q"
    if ($html -notmatch '(?i)<title>[^<]*Tunisianet') { throw 'Tunisianet search page not recognised (blocked or changed?)' }
    foreach ($b in ($html -split '(?=<article[^>]*product-miniature)')) {
        if ($b -notmatch '^<article') { continue }
        $end = $b.IndexOf('</article>'); if ($end -gt 0) { $b = $b.Substring(0, $end) }
        $m = [regex]::Match($b, '<h2 class="h3 product-title"[^>]*><a href="([^"]+)">([^<]+)</a>')
        if (-not $m.Success) { continue }
        $price = ConvertFrom-TunisianetPrice ([regex]::Match($b, 'itemprop="price"[^>]*>([^<]*)').Groups[1].Value)
        $st = [regex]::Match($b, 'id="stock_availability">\s*<span class="([^"]*)">([^<]*)')
        $inStock = $null; $note = ''
        if ($st.Success) {
            $inStock = ($st.Groups[1].Value -eq 'in-stock')
            if (-not $inStock) { $note = $st.Groups[2].Value.Trim() }
        }
        New-Listing ([Net.WebUtility]::HtmlDecode($m.Groups[2].Value).Trim()) $price $inStock $m.Groups[1].Value -Note $note
    }
}

