# Amiibank

An open-source iPhone app for keeping a collection of amiibo backups, writing them to blank
NTAG215 tags, and managing the banks of an N2 Elite (Amiiqo) emulator.

Not affiliated with Nintendo. This repo contains no Nintendo keys and no amiibo dumps.
Bring your own `key_retail.bin` and back up amiibo you own.

## What it does

- **Library:** import single `.bin` dumps (532, 540 or 572 bytes) or a combined backup made of
  back-to-back 572-byte entries. Duplicates (same amiibo ID) are skipped. Files live in
  `Documents/Library`, so they also show up in the Files app.
- **Write NTAG215:** re-signs the dump for the blank tag's UID, writes it, then sets the password
  and lock bits. The tag is read-only afterwards.
- **N2 Elite:** scan slots, see the active amiibo, add to the next empty slot, replace a slot,
  save a slot to the library, randomize a slot's serial, and change how many slots the button cycles.
- **Games:** every Switch, 3DS and Wii U game that reads amiibo, what each amiibo does in it, and a
  multi-select that loads the ones you own onto the N2 in one go.
- **Game Center backup:** the collection and app state saved as Game Center saved games. Copies
  from different devices merge, so nothing one device added is lost.

## Build

Requires Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and a paid Apple developer
team (NFC tag reading isn't available to free teams).

```sh
cp Signing.xcconfig.example Signing.xcconfig   # set DEVELOPMENT_TEAM and AMIIBANK_BUNDLE_ID
xcodegen generate
open Amiibank.xcodeproj
```

Core logic tests run on the Mac with fake keys:

```sh
cd Packages/AmiiboKit && swift test
```

To check the crypto against real data you own, point the opt-in test at your files:

```sh
AMIIBANK_KEY=/path/key_retail.bin AMIIBANK_DUMP=/path/amiibo.bin swift test --filter realKey
```

## Layout

| Path | Holds |
| --- | --- |
| `Packages/AmiiboKit` | Pure logic: dump parsing, amiibo crypto, NTAG215 write plan, N2 commands |
| `App` | SwiftUI app and the Core NFC session |
| `scripts/update-db.sh` | Refreshes the bundled AmiiboAPI catalog in `App/Resources` |

## Sources

- Amiibo crypto: port of [amiitool](https://github.com/socram8888/amiitool) (MIT).
- N2 Elite commands: Proxmark3 traces on [YobiWiki](https://wiki.yobi.be/index.php/N2_Elite).
- NTAG215 lock and config pages: [NXP NTAG213/215/216 datasheet](https://www.nxp.com/docs/en/data-sheet/NTAG213_215_216.pdf).
- Catalog, game usage and pictures: [AmiiboAPI](https://github.com/N3evin/AmiiboAPI) (MIT).

## License

MIT. See `LICENSE`.
