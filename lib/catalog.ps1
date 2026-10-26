# data\catalog.json lists product families compactly; Expand-Catalog turns them into the products the tracker checks.
#   sizes  one product per storage size ("256GB" adds the include word "256", "1TB" adds "1tb"); all sizes of a family
#          share one search per store where the checker allows it
#   group  a whole range, e.g. "Bosch dishwashers": the page lists every matching model instead of one per store
#   ex     a shared exclude list from the catalog's "exclude" sets; not: extra words to exclude
#   every  check every N runs (default: the section's "every" in settings.json; 1 = every run)
#   hot    a launch or hard-to-get product: checked every run
function ConvertTo-Slug([string]$Text) { ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') }

function Expand-Catalog([string]$Path, $Sections) {
    $cat = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $sets = @{}
    foreach ($p in $cat.exclude.PSObject.Properties) { $sets[$p.Name] = @($p.Value) }
    $every = @{}; $types = @{}
    foreach ($s in @($Sections)) { if ($s.every) { $every[$s.name] = [int]$s.every }; if ($s.types) { $types[$s.name] = @($s.types) } }
    # A section's "types" (settings.json) sort its families for the page's tree: the first type with a word found in
    # the family's name wins ("type" in the catalog overrides), anything else is "Other".
    $typeOf = {
        param($f)
        if ($f.type) { return $f.type }
        if (-not $types[$f.section]) { return '' }
        $n = ' ' + (ConvertTo-Slug "$($f.name) $($f.query)").Replace('-', ' ') + ' '
        foreach ($t in $types[$f.section]) { foreach ($w in @($t.words)) { if ($n.Contains(' ' + $w)) { return $t.name } } }
        'Other'
    }
    foreach ($f in @($cat.products)) {
        if ($f.disabled) { continue }
        $family = if ($f.id) { $f.id } else { ConvertTo-Slug $f.name }
        $query = if ($f.query) { $f.query } elseif ($f.name -match [regex]::Escape($f.brand)) { $f.name.ToLowerInvariant() } else { "$($f.brand) $($f.name)".ToLowerInvariant() }
        $exclude = @(@($sets["$($f.ex)"]) + @($f.not) | Where-Object { $_ })
        $base = [ordered]@{
            id = $family; family = $family; familyName = $f.name; size = ''; name = $f.name; brand = $f.brand; category = $f.section; type = (& $typeOf $f); query = $query; queries = $f.queries
            include = @($f.match); exclude = $exclude; minUsd = $f.minUsd; group = [bool]$f.group; ids = $f.ids; countries = $f.countries
            hot = [bool]$f.hot
            every = $(if ($f.every) { [int]$f.every } elseif ($f.hot) { 1 } elseif ($every[$f.section]) { $every[$f.section] } else { 1 })
        }
        if (-not $f.sizes) { [pscustomobject]$base; continue }
        foreach ($size in @($f.sizes)) {
            $p = [ordered]@{}; foreach ($k in $base.Keys) { $p[$k] = $base[$k] }
            $term = if ("$size" -match '^(\d+)\s*GB$') { $Matches[1] } else { ("$size".ToLowerInvariant() -replace '\s+', '') }
            $p.id = "$family-$(ConvertTo-Slug $size)"; $p.name = "$($f.name) $size"; $p.size = "$size"; $p.include = @(@($f.match) + $term)
            [pscustomobject]$p
        }
    }
}
