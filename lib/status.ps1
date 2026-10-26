# Turns what a store returned for one product into result rows: one per city with branch stock,
# or a single row with City '' for online stock that covers the whole country.
# Status: InStock, Unverified (store says in stock but isn't reliable, or doesn't say), OutOfStock (listed but
# can't be bought now, pre-orders included), NotFound (no listing matches the product).
# A "group" product (e.g. "Bosch dishwashers") gets one row per model the store has available instead.
function Resolve-Rows($Store, $Product, $Listings, $Country) {
    $listed = @($Listings | Where-Object { $_ -is [hashtable] })
    if ($listed | Where-Object { $_.Skip }) { return }
    $rate = if ($Country -and $Country.usdRate) { [double]$Country.usdRate } else { 1 }
    # The price floor drops accessories and parts that share the product's name.
    $matched = @($listed | Where-Object { $_.Title -and (Test-ProductMatch $Product $_.Title) -and
        ($null -eq $_.Price -or -not $Product.minUsd -or ($_.Price / $rate) -ge [double]$Product.minUsd) })
    $byPrice = @{ e = { if ($null -ne $_.Price) { $_.Price } else { [double]::MaxValue } } }
    # Missing values are an explicit $null: an "if" with no else gives PowerShell's empty result, which is saved as {}.
    $row = {
        param($Key, $City, $Status, $Best, $Note, $Count)
        [pscustomobject]@{
            Key = $Key; Store = $Store.id; Product = $Product.id; City = $City; Status = $Status
            Price = $(if ($Best) { $Best.Price } else { $null }); Title = $(if ($Best) { $Best.Title } else { '' })
            Url = $(if ($Best -and $Best.Url) { $Best.Url } else { $Store.url }); Note = $Note; Matches = $Count
            Coupon = $(if ($Best) { $Best.Coupon } else { $null }); CouponPrice = $(if ($Best) { Get-CouponPrice $Best.Price $Best.Coupon } else { $null })
            Image = $(if ($Best) { $Best.Image } else { $null })
        }
    }

    if ($Product.group) {
        $ok = @($matched | Where-Object { $_.InStock -ne $false -and -not $_.PreOrder } | Sort-Object $byPrice | Select-Object -First 12)
        if (-not $ok) { & $row "$($Store.id)|$($Product.id)|" '' 'NotFound' $null '' 0; return }
        foreach ($l in $ok) {
            $st = if ($l.InStock -eq $true -and -not $Store.weak) { 'InStock' } else { 'Unverified' }
            & $row "$($Store.id)|$($Product.id)|$($l.City)|$(Get-ShortHash "$(if ($l.Url) { $l.Url } else { $l.Title })")" "$($l.City)" $st $l "$($l.Note)" 1
        }
        return
    }

    $cities = @($matched | ForEach-Object { "$($_.City)" } | Sort-Object -Unique)
    if (-not $cities) { $cities = @('') }
    foreach ($city in $cities) {
        $group   = @($matched | Where-Object { "$($_.City)" -eq $city })
        $avail   = @($group | Where-Object { $_.InStock -eq $true -and -not $_.PreOrder } | Sort-Object $byPrice)
        $unknown = @($group | Where-Object { $null -eq $_.InStock -and -not $_.PreOrder } | Sort-Object $byPrice)
        $note = ''
        if ($avail) { $status = if ($Store.weak) { 'Unverified' } else { 'InStock' }; $best = $avail[0] }
        elseif ($unknown) { $status = 'Unverified'; $best = $unknown[0] }
        elseif ($group) {
            $status = 'OutOfStock'; $best = @($group | Sort-Object $byPrice)[0]
            if ($group | Where-Object { $_.PreOrder }) { $note = 'Pre-order only' }
        } else { $status = 'NotFound'; $best = $null }
        if ($best -and $best.Note) { $note = (@($note, $best.Note) | Where-Object { $_ }) -join ' | ' }
        if ($status -eq 'Unverified' -and $Store.weak -and $avail) { $note = (@($note, "store says in stock; call before going") | Where-Object { $_ }) -join ' | ' }
        & $row "$($Store.id)|$($Product.id)|$city" $city $status $best $note $group.Count
    }
}

# Price after the store's coupon, only when anyone buying this one item gets it:
#   "You pay SAR 189.99 with coupon" (Amazon: already the final price)    -> 189.99
#   "Save 5% with coupon", "Extra 10% off up to 50 AED"                   -> percent off, capped by "up to"
#   "Save AED 100.00 with coupon", "AED 50 off"                           -> amount off
#   "... on orders over 200 AED"                                           -> only if this item reaches the minimum
# Nothing for bank-card-only codes or "Up to 250 AED off" (a maximum, not a promised saving), or anything unclear.
function Get-CouponPrice($Price, [string]$Text) {
    if (-not $Price -or -not $Text) { return $null }
    $t = $Text -replace '(?<=\d),(?=\d)', ''
    $cur = 'AED|SAR|QAR|KWD|BHD|OMR|EGP|JOD|IQD|USD|Dhs?|SR'
    $amount = "(?:(?:$cur)\.?\s*(\d+(?:\.\d+)?)|(\d+(?:\.\d+)?)\s*(?:$cur)\b)"
    $num = { param($m) if ($m.Groups[1].Success) { [double]$m.Groups[1].Value } else { [double]$m.Groups[2].Value } }
    $m = [regex]::Match($t, "you pay\s+$amount", 'IgnoreCase')
    if ($m.Success) { $v = & $num $m; if ($v -gt 0 -and $v -lt $Price) { return [Math]::Round($v, 2) }; return $null }
    if ($t -match '(?i)\b(card|cards|bank|credit|debit|wallet|first order|new customer)') { return $null }
    $min = [regex]::Match($t, "(?i)(?:orders?|spend|purchases?|min(?:imum)?(?: order| spend)?)\s+(?:over|above|of|from)?\s*$amount")
    if ($min.Success -and $Price -lt (& $num $min)) { return $null }
    $pct = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*%')
    if ($pct.Success) {
        $v = [double]$pct.Groups[1].Value
        if ($v -le 0 -or $v -ge 90) { return $null }
        $off = $Price * $v / 100
        $cap = [regex]::Match($t.Substring($pct.Index), "(?i)up to\s+$amount")
        if ($cap.Success) { $off = [Math]::Min($off, (& $num $cap)) }
        return [Math]::Round($Price - $off, 2)
    }
    if ($t -match '(?i)^\W*up to\b') { return $null }
    $m = [regex]::Match($t, "(?i)(?:save|off|discount)\D{0,12}$amount|$amount\s*(?:off|discount)")
    if (-not $m.Success) { return $null }
    $v = if ($m.Groups[1].Success) { [double]$m.Groups[1].Value } elseif ($m.Groups[2].Success) { [double]$m.Groups[2].Value } elseif ($m.Groups[3].Success) { [double]$m.Groups[3].Value } else { [double]$m.Groups[4].Value }
    if ($v -gt 0 -and $v -lt $Price) { [Math]::Round($Price - $v, 2) } else { $null }
}

# Shorter product links for the page: Amazon's /dp/<ASIN> without tracking, Noon without its navigation context.
function Compress-Url([string]$Url) {
    if ($Url -match '^(https://[^/]*amazon\.[a-z.]+)/.*?/dp/([A-Z0-9]{10})') { return "$($Matches[1])/dp/$($Matches[2])" }
    if ($Url -match 'noon\.com') { return ($Url -replace '[?&]nav_ctx=[^&]*', '') }
    $Url
}

# Short stable id for a listing (SHA-256: MD5 isn't allowed on FIPS-locked Windows).
function Get-ShortHash([string]$Text) {
    $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    (($h | Select-Object -First 5) | ForEach-Object { $_.ToString('x2') }) -join ''
}
