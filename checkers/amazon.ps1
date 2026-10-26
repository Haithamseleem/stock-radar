# Amazon: parses the public search page (/s?k=...). A result with a price (buy box) is orderable; "Currently
# unavailable" or no price (only "No featured offers available" / other sellers) is not.
# Amazon sometimes answers with a short "bm-verify" bot-check page (more often after several quick requests);
# the checker waits and retries once or twice (alternating curl / Invoke-WebRequest), then throws.
# Store fields: host (e.g. amazon.ae).
function Get-AmazonSearchPage($Store, [string]$Query) {
    $url = "https://www.$($Store.host)/s?k=$Query"
    for ($try = 1; $try -le 3; $try++) {
        $html = $null
        try { $html = if ($try % 2 -eq 1) { Get-Curl $url -Cookies } else { Get-Web $url } } catch { $html = $null }
        if ($html -and $html -match 'data-component-type="s-search-result"') { return $html }
        if ($html -and $html -match 'did not match any products|No results for') { return $html }
        if ($try -lt 3) { Start-Sleep -Seconds (4 * $try) }
    }
    throw 'Amazon returned a bot-check page instead of search results'
}

# The coupon / promo-code text a result card shows, exactly as displayed (tags dropped, spaces squeezed), or ''.
# 1) the visible coupon badge: <span class="s-coupon-unclipped"> "You pay SAR 189.99 with coupon" (older pages: "Save AED 100.00 with coupon");
#    the hidden s-coupon-clipped twin ("5% off coupon applied") is the same offer and is not passed.
# 2) a plain promo line (<span>text</span>) that names a code / promo / voucher / coupon, e.g. "Extra 10% off with code ABC".
#    Quantity ("Buy 5, get 5% off") and bank-card ("20% off NBE Visa ...") lines are not coupons and are ignored.
function Get-AmazonCoupon([string]$Card) {
    $c = [regex]::Replace($Card, '<h2[\s\S]*?</h2>', ' ')
    $found = @()
    $m = [regex]::Match($c, '<span class="s-coupon-unclipped[^"]*">((?:\s*<span[^>]*>[^<]*</span>)+)\s*</span>')
    if ($m.Success) { $found += ([Net.WebUtility]::HtmlDecode(([regex]::Replace($m.Groups[1].Value, '<[^>]+>', ' ') -replace '\s+', ' '))).Trim() }
    foreach ($s in [regex]::Matches($c, '<span>([^<]{4,160})</span>')) {
        $t = ([Net.WebUtility]::HtmlDecode($s.Groups[1].Value) -replace '\s+', ' ').Trim()
        if ($t -match '(?i)\b(promo(tion)?(al)? code|coupon code|with code|use code|voucher|coupon)\b' -and $found -notcontains $t) { $found += $t }
    }
    $found -join ' | '
}

function Find-amazon($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $html = Get-AmazonSearchPage $Store $q
    $cards = [regex]::Split($html, '(?=<div[^>]*data-component-type="s-search-result")') |
        Where-Object { $_ -match '^<div[^>]*data-component-type="s-search-result"' }
    $seen = @{}
    foreach ($c in $cards) {
        $asin = [regex]::Match($c, 'data-asin="([A-Z0-9]{10})"').Groups[1].Value
        if (-not $asin -or $seen[$asin]) { continue }
        $seen[$asin] = $true
        $title = [regex]::Match($c, '<h2[^>]*aria-label="([^"]+)"').Groups[1].Value
        if (-not $title) { $title = [regex]::Match($c, '<h2[^>]*>[\s\S]*?<span[^>]*>([^<]+)</span>').Groups[1].Value }
        $title = ([Net.WebUtility]::HtmlDecode($title) -replace '^Sponsored Ad\W+', '').Trim()
        if (-not $title) { continue }
        $link = "https://www.$($Store.host)/dp/$asin"
        $text = [Net.WebUtility]::HtmlDecode(([regex]::Replace($c, '<[^>]+>', ' ') -replace '\s+', ' '))
        $price = [regex]::Match($c, 'class="a-price"[^>]*>\s*<span class="a-offscreen">([^<]+)</span>').Groups[1].Value
        $img = [regex]::Match([regex]::Match($c, '<img[^>]*class="s-image"[^>]*>').Value, ' src="(https://[^"]+)"').Groups[1].Value
        if ($price -and $text -notmatch 'Currently unavailable|Temporarily out of stock') {
            $note = [regex]::Match($text, 'Only \d+ left in stock').Value
            New-Listing $title $price $true $link -Note $note -Coupon (Get-AmazonCoupon $c) -Image $img
        } else {
            $m = [regex]::Match($text, '([\d,]+(?:\.\d+)?)\s*\((\d+) new offers?\)')
            $note = if ($m.Success) { "no featured offer; $($m.Groups[2].Value) other-seller offer(s) from $($m.Groups[1].Value)" } else { 'unavailable' }
            New-Listing $title $m.Groups[1].Value $false $link -Note $note -Image $img
        }
    }
}
