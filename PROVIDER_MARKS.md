# Provider marks

The provider picker uses compact provider marks in a shared 20-point icon slot.
Use the provider's published artwork rather than a text glyph or a locally
redrawn approximation. These assets identify integrations; they are not Kestrel
branding.

- Codex CLI: OpenAI Blossom SVG from [OpenAI Brand](https://openai.com/brand/). The user explicitly agreed to OpenAI's marks-usage terms before the official asset was added. It remains monochrome in the picker.
- Kilo CLI: the Kilo mark is sourced from the official [Kilo Code repository](https://github.com/Kilo-Org/kilocode/tree/main/packages/kilo-vscode/assets/icons), where Kilo publishes its integration artwork.
- OpenRouter: current glyph SVGs from [OpenRouter Brand](https://openrouter.ai/brand): Grape for light surfaces and Volt for dark surfaces. The official variants are used as-is and are not recoloured.
- Mistral: current pixel emblem from the official [Mistral Brand kit](https://mistral.ai/brand/), using its published gradient-colour SVG instead of the earlier obsolete mark.
- Apple On-Device: uses Apple's native `apple.intelligence` SF Symbol on macOS 26 and later, with the generic `sparkles` symbol as a fallback on older supported macOS versions. The official symbol is used only to identify Apple On-Device/Apple Intelligence; it is not modified or used as Kestrel branding.
- Google Gemini: the official Gemini sparkle glyph from [Simple Icons](https://simpleicons.org/?q=gemini) (`googlegemini`). Rendered as a template so it stays legible in either appearance.
- Groq: the official Groq "G" glyph. The source SVG (`https://svgl.app/library/groq.svg`) is the brand mark on its orange tile; the tile background path was removed and the glyph kept, so an empty frame does not become a solid block in the small icon slot.
- DeepSeek: the official DeepSeek glyph from [Simple Icons](https://simpleicons.org/?q=deepseek) (`deepseek`), rendered as a template.
- xAI Grok: the X glyph from [Simple Icons](https://simpleicons.org/?q=x) (`x`), since xAI publishes its Grok branding under the X mark. Rendered as a template so the black glyph stays visible in dark mode.
- OpenAI-compatible: reuses the existing OpenAI Blossom asset, because that generic slot defaults to OpenAI's own endpoint and is repointed only by the user.

All five new marks are drawn as single-colour templates, matching the Codex and Kilo marks, so one asset works in light and dark appearance. They are recognisable official glyph shapes rather than locally redrawn approximations; no vendor terms are implied beyond the trademarks themselves, and a coloured variant can be added for any of them by dropping the published artwork into `KestrelWebKit/Assets.xcassets` and switching that case to `assetMark`.

The SVGs are packaged in `KestrelWebKit/Assets.xcassets` for both the Xcode app
and SwiftPM resource bundle. The picker keeps every mark within a consistent
icon frame. The shared OpenAI Blossom asset uses a view box trimmed to the
official artwork's bounds, with a small clear margin, so the Codex and generic
OpenAI marks fill that frame at the same visual size as the other providers.
