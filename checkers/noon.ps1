# Noon: the site's own search API. "is_buyable" says whether it can be ordered now.
# The country is picked by the x-locale request header (en-ae, en-sa, en-eg); without it the API answers for the UAE.
# Store fields: locale (the URL prefix for links, e.g. uae-en), xlocale (the header value, default en-ae).
function Find-noon($Store, $Product) {
    $q = [uri]::EscapeDataString((Get-ProductQuery $Store $Product))
    $xl = if ($Store.xlocale) { $Store.xlocale } else { 'en-ae' }
    $json = Get-Curl "https://www.noon.com/_svc/catalog/api/v3/u/search?limit=50&q=$q" -Headers @("x-locale: $xl") | ConvertFrom-Json
    if ($null -eq $json.hits) { throw 'Noon search returned no results (blocked?)' }
    foreach ($h in $json.hits) {
        $price = if ($h.sale_price) { $h.sale_price } else { $h.price }
        New-Listing $h.name $price ([bool]$h.is_buyable) "https://www.noon.com/$($Store.locale)$($h.pdp_url)" `
            -Coupon (Get-NoonCoupon $h) -Image $(if ($h.image_key) { "https://f.nooncdn.com/p/$($h.image_key).jpg?format=jpg&width=400" } else { '' })
    }
}

# The promo tag Noon shows on a hit, as the store words it: discount_code_display_text ("CODE: SAVEBIG") and
# discount_tag_detail ("Extra 10% off on orders over 200 AED"; the title alone when there is no detail).
# Many codes are limited (bank cards, a minimum order); the detail says so and discount_tag_terms has the fine print.
function Get-NoonCoupon($Hit) {
    $code = ("$($Hit.discount_code_display_text)" -replace '\s+', ' ').Trim()
    $text = ("$($Hit.discount_tag_detail)" -replace '\s+', ' ').Trim()
    if (-not $text) { $text = ("$($Hit.discount_tag_title)" -replace '\s+', ' ').Trim() }
    (@($code, $text) | Where-Object { $_ }) -join ' - '
}
