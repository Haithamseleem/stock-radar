# Apple online store: looks products up by part number (data\products.json "ids", key apple-<country>), not by search words.
# Online delivery comes from the store's delivery-message endpoint; Apple Store pick-up (one listing per city) from the
# retail pickup-message endpoint, which lists the country's stores with a stock state per part.
# Store fields: locale (URL prefix, e.g. ae), pickup (true when the country has Apple Stores), cities (cities with an Apple Store).
function Get-AppleEtaDate([string]$Text) {
    if (-not $Text) { return $null }
    $mon = 'jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec'
    $m = [regex]::Match($Text, "(?<d>\d{1,2})(?:st|nd|rd|th)?\s+(?<m>$mon)[a-z]*(?:'(?<y>\d{2})|\s+(?<y>\d{4}))?", 'IgnoreCase')
    if (-not $m.Success) { $m = [regex]::Match($Text, "(?<m>$mon)[a-z]*\s+(?<d>\d{1,2})(?:,?\s+(?<y>\d{4}))?", 'IgnoreCase') }
    if (-not $m.Success) { return $null }
    $month = (@($mon -split '\|')).IndexOf($m.Groups['m'].Value.ToLower()) + 1
    $today = (Get-Date).Date
    try {
        if ($m.Groups['y'].Success) {
            $year = [int]$m.Groups['y'].Value
            if ($year -lt 100) { $year += 2000 }
            return [datetime]::new($year, $month, [int]$m.Groups['d'].Value)
        }
        $eta = [datetime]::new($today.Year, $month, [int]$m.Groups['d'].Value)
        if ($eta -lt $today.AddDays(-1)) { $eta = $eta.AddYears(1) }
        $eta
    } catch { $null }
}

# A delivery or pick-up promise more than a week out (or with no date and no "today/tomorrow") is a pre-order, not stock.
function Test-ApplePreorder([string]$Text, [bool]$UndatedMeansPreorder) {
    $eta = Get-AppleEtaDate $Text
    if ($eta) { return (($eta - (Get-Date).Date).TotalDays -gt 7) }
    if ($UndatedMeansPreorder) { return ($Text -notmatch 'in stock|today|tomorrow|business day|within \d+ days') }
    $false
}

function Find-apple($Store, $Product) {
    $parts = @($Product.ids.("apple-$($Store.country)") | Where-Object { $_ })
    if (-not $parts) { return Skip-Product }
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 20MB
    $read = {
        param($Url)
        try { $ser.DeserializeObject((Get-Curl $Url)) } catch { throw 'Apple answered with something that is not JSON (blocked?)' }
    }
    $loc = $Store.locale
    $name = { param($p) "$($Product.name) ($p)" }
    $link = { param($p) "https://www.apple.com/$loc/shop/product/$p" }

    # Online delivery, all part numbers in one request.
    $qs = (0..($parts.Count - 1) | ForEach-Object { 'parts.{0}={1}&mts.{0}=regular' -f $_, [uri]::EscapeDataString($parts[$_]) }) -join '&'
    $dm = & $read "https://www.apple.com/$loc/shop/delivery-message?$qs"
    $msgs = $dm['body']['content']['deliveryMessage']
    if (-not $msgs) { throw 'Apple returned no delivery data' }
    $got = 0
    foreach ($p in $parts) {
        $m = $null
        if ($msgs.ContainsKey($p) -and $msgs[$p].ContainsKey('regular')) { $m = $msgs[$p]['regular'] }
        if (-not $m) { continue }
        $got++
        $buyable = [bool]$m['isBuyable']
        $text = (@($m['deliveryOptionMessages']) | ForEach-Object { $_['displayName'] }) -join '; '
        if (-not $buyable) { $text = 'Currently unavailable' }
        New-Listing (& $name $p) $null $buyable (& $link $p) -Note $text -PreOrder:($buyable -and (Test-ApplePreorder $text $true))
    }
    if (-not $got) { throw "Apple returned no delivery data for $($parts -join ', ')" }

    # Apple Store pick-up per city. One request normally lists every store in the country, so ask for another city only
    # if some city is still missing from the answer.
    if (-not $Store.pickup) { return }
    $byCity = @{}
    foreach ($city in @($Store.cities)) {
        if ($byCity.ContainsKey($city)) { continue }
        $pq = (0..($parts.Count - 1) | ForEach-Object { 'parts.{0}={1}' -f $_, [uri]::EscapeDataString($parts[$_]) }) -join '&'
        $pm = & $read "https://www.apple.com/$loc/shop/retail/pickup-message?pl=true&$pq&location=$([uri]::EscapeDataString($city))"
        $stores = $pm['body']['stores']
        if (-not $stores) { continue }
        foreach ($s in $stores) {
            $c = "$($s['city'])"
            if (-not $c) { continue }
            if (-not $byCity.ContainsKey($c)) { $byCity[$c] = @() }
            if (-not ($byCity[$c] | Where-Object { $_['storeName'] -eq $s['storeName'] })) { $byCity[$c] += $s }
        }
    }
    foreach ($city in @($Store.cities)) {
        if (-not $byCity.ContainsKey($city)) { continue }
        foreach ($p in $parts) {
            $open = @(); $quote = ''
            foreach ($s in $byCity[$city]) {
                $pa = $s['partsAvailability'][$p]
                if ($pa -and $pa['pickupDisplay'] -eq 'available') {
                    $open += $s['storeName']
                    if (-not $quote) {
                        $quote = "$($pa['pickupSearchQuote'])"
                        $rm = $pa['messageTypes']
                        if ($rm -and $rm['regular'] -and $rm['regular']['storePickupQuote']) { $quote = "$($rm['regular']['storePickupQuote'])" }
                    }
                }
            }
            $note = if ($open) { 'Pick-up at Apple ' + ($open -join ', ') } else { '' }
            New-Listing (& $name $p) $null ([bool]$open) (& $link $p) -Note $note -City $city -PreOrder:([bool]$open -and (Test-ApplePreorder $quote $false))
        }
    }
}
