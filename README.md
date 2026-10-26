# Stock Radar

**Live page:** https://haithamseleem.github.io/stock-radar/

Which stores have the phone, console or gadget you want in stock right now, across the GCC and Arab countries.
Stores are checked automatically about every 15-20 minutes with GitHub Actions; pick your country, city and product on the page.

- Products: `data/products.json` (search words, words to ignore, price floor)
- Stores: `data/stores/*.json`, one file per shopping platform; checkers in `checkers/` (see CHECKERS.md)
- Countries, cities and Telegram channels: `data/countries.json`