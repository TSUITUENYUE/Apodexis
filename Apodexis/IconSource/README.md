## App Icon Source

`Greek_Alpha_03.svg` is the original SVG downloaded from Wikimedia Commons:

https://commons.wikimedia.org/wiki/File:Greek_Alpha_03.svg

The Commons file page identifies it as public domain. It is kept here as the Alpha reference used during icon exploration.

The current Apodexis app icon is generated from `ApodexisIconAI.png`, an AI-generated raster icon with an ancient Greek marble tablet style and an incised Alpha.

Regenerate the app icon assets with:

```sh
python3 Apodexis/IconSource/generate_app_icon.py
```

The generator expects Pillow. It center-crops the source PNG and writes the macOS app icon PNG sizes.

Final AI prompt:

```text
Create a polished app icon for an app named Apodexis, with an ancient Greek scholarly / epigraphic feeling. The icon is a rounded-square white marble tablet, warm ivory white stone, realistic natural gray-brown marble veins, fine stone grain, subtle worn rounded edges, high-end macOS icon finish. In the center, carve a single large black ancient Greek uppercase Alpha into the stone: angular epigraphic Alpha, not a modern font, not Latin typography, one bold symbol only. The letter should feel incised / engraved into the marble with dark recessed interior, sharp stone-cut bevels, and subtle inner shadows. Composition should be centered, clean, readable at small app-icon sizes. Avoid extra letters, words, labels, watermark, decorative border, columns, statues, gold, blue, purple, modern sans-serif letter A, flat vector look, and cartoon style.
```
