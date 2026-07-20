# Map card artwork

Screenshots of each standard preset, shown on the cards in the map picker
(`MapSelectionView`). Loaded by filename from the app bundle, so replacing a
picture is a matter of dropping a new file in — no code or asset-catalogue edit.

Expected filenames (`.jpg`, `.jpeg` or `.png` all work):

| File                      | Preset        |
|---------------------------|---------------|
| `map-card-gridDemo.*`     | reference grid |
| `map-card-field.*`        | open field with scattered trees |
| `map-card-forest.*`       | dense forest |
| `map-card-cargoYard.*`    | container terminal |
| `map-card-city.*`         | abandoned settlement |

Cards are 240–340 pt wide and crop to a 150 pt strip, so a landscape frame of
roughly 3:2 or wider reads best. A missing file is not an error — the card falls
back to a coloured placeholder and stays usable.
