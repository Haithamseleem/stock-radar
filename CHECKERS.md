# Writing a store checker

A checker teaches the tracker to search one shopping platform (often the same platform in several countries).

## Files
- `checkers/<adapter>.ps1` defines `function Find-<adapter>($Store, $Product)`; `<adapter>` is lower case, e.g. `Find-carrefour`.
- `data/stores/<adapter>.json` is an array of stores using it, one per country (or per site):
  `{ "id": "carrefour-ae", "name": "Carrefour", "adapter": "carrefour", "country": "AE", "url": "<home or search page>", ...your own fields }`
  Optional: `"cities": [...]` for a shop with branches only in some cities, `"weak": true` when its "in stock" flag is unreliable,
  `"disabled": true, "reason": "..."` for a store that can't be checked automatically (it stays out of runs).
- Country codes and city names: `data/countries.json`. Products: `data/products.json` (don't edit; `Get-ProductQuery` gives the search words).

## The contract
- Search the store with `Get-ProductQuery $Store $Product` and return every result as `New-Listing $title $price $inStock $url [-Note ..] [-City ..] [-PreOrder]`.
  Return all results; the runner does the matching (include/exclude words, price floor). `$inStock`: `$true` orderable now, `$false` not, `$null` the store doesn't say.
- Price in the store's own currency (the country's currency in countries.json). Links must be absolute https URLs on the store's site.
- City-level stock (pick-up or branch stock) only when the store exposes it cheaply: one listing per city, `-City` exactly as in countries.json.
- Throw when the store answers with something unusable (blocked, captcha, changed page) so it shows as "couldn't check"; return nothing when the search really found nothing.
- `Skip-Product` when the product can't be looked up there at all (e.g. Apple needs part numbers from the product's `ids`).

## Rules
- Windows PowerShell 5.1: no `?:`, `??`, `&&`, `||`, `-Parallel`. Use `Get-Web`/`Get-WebJson` (Invoke-WebRequest, UTF-8) or `Get-Curl` (curl.exe, for sites that stall or block the first) from `lib/common.ps1`.
- All functions from every file are loaded together, so helper functions must carry the adapter name (`Get-CarrefourToken`), and nothing may run outside a function.
- Be polite: one or two requests per product search, public search pages or the site's own public JSON APIs only; no logins, captcha solving or browser automation.
- Prefer the English version of a site.

## Testing
- `.\probe.ps1 -Store carrefour-ae -Product ps5-pro` lists what the store returned (+ = matches the product).
- `.\probe.ps1 -Store carrefour-ae -Query "iphone"` raw search with any words.
- `.\tracker.ps1 -Store carrefour-ae,carrefour-sa` shows the final status per product (test runs save and send nothing).
