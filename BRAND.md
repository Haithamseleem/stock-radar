# Stock Radar brand guide

**What it is:** a free page that shows which stores in the Middle East have a product in stock right now and who sells it cheapest.
**Voice:** short, factual and helpful. Say what's true now ("In stock at 7 stores", "Best price AED 4,349"), never hype, never invent savings.
Prefer plain words: "in stock", "best price", "search it yourself", "unconfirmed: call before you go".

## Logo
| File | Use |
|---|---|
| `site/brand/mark.svg` | App icon / avatar: gradient rounded square, radar sweep, green "in stock" blip |
| `site/brand/logo.svg` | Mark + "Stock Radar" wordmark, for light backgrounds |
| `site/brand/logo-white.svg` | Same for dark or gradient backgrounds |
| `site/favicon.svg`, `site/apple-touch-icon.png` | Browser tab and phone home-screen icons |
| `site/brand/telegram-channel-640.png` | Telegram channel picture (Telegram crops it to a circle; the radar stays inside) |

Keep clear space around the logo of at least the blip's diameter; don't recolour, stretch, outline or add effects to the mark.

## Colours
| Name | Hex | Use |
|---|---|---|
| Navy | `#162d3d` | Text, side menu, dark surfaces |
| Blue | `#0f62e6` | Primary buttons, links, focus rings (5.4:1 on white) |
| Violet | `#7c3aed` | Gradient end (with Blue, 135°) |
| Green | `#157a3e` on `#e6f7ec` | "In stock" and best-price text (4.9:1); `#22c55e` only for dots, ribbons and the blip |
| Amber | `#8f5600` on `#fff4e0` | "Unconfirmed" (5.6:1) |
| Purple | `#5b3bd6` on `#f1edff` | Coupons and discount cards (6.0:1) |
| Muted | `#5f6b78` | Secondary text (5.4:1 on white) |
| Background / Line | `#f0f4f7` / `#dfe5eb` | Page background, borders |

All text colours meet WCAG AA (4.5:1). Never show status by colour alone: always with a word ("In stock", "Unconfirmed").

## Typography
"Madefor Text", then Inter, Segoe UI, system UI. Headlines 700-800 with slightly tight letter spacing; body 15px desktop / 16px phones; nothing under 12px.

## Banners (`site/brand/banners/`, made by `render-brand.ps1` from `banner.html`)
| File | Size | Where |
|---|---|---|
| `link-preview-{gradient,light}-1200x630.png` | 1200×630 | Shown when the link is shared (WhatsApp, Telegram, X, Facebook). `site/brand/og-image.png` is the one in use |
| `post-{gradient,light}-1080x1080.png` | 1080×1080 | Instagram / WhatsApp / Telegram posts |
| `story-{gradient,light}-1080x1920.png` | 1080×1920 | Instagram / WhatsApp status stories |

Two art directions: **Gradient** (brand gradient, white text: bold, stands out in chats) and **Light** (dashboard grey, navy text: calm, matches the app).
One call to action per banner, key content inside the central 80%. The comparison card uses example values and "Store A/B/C" on purpose.
To switch the link preview: `.\render-brand.ps1 -LinkPreview light`.
