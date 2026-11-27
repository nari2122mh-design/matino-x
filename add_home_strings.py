#!/usr/bin/env python3
"""Add the home screen design keys to each Localizable.strings file."""
from __future__ import annotations

import io
from pathlib import Path

ROOT = Path(__file__).resolve().parent / "ThreeOneOSFive"

ENTRIES: dict[str, list[tuple[str, str]]] = {
    "en": [
        ("home.brand_info", "MATINO X \u2022 Official info"),
        ("home.select_hint", "Select a package"),
        ("common.open", "Open"),
    ],
    "vi": [
        ("home.brand_info", "MATINO X \u2022 Th\u00f4ng tin ch\u00ednh th\u1ee9c"),
        ("home.select_hint", "Ch\u1ecdn g\u00f3i"),
        ("common.open", "M\u1edf"),
    ],
    "zh-Hans": [
        ("home.brand_info", "MATINO X \u2022 \u5b98\u65b9\u4fe1\u606f"),
        ("home.select_hint", "\u9009\u62e9\u8f6f\u4ef6\u5305"),
        ("common.open", "\u6253\u5f00"),
    ],
}


def main() -> int:
    for locale, pairs in ENTRIES.items():
        path = ROOT / f"{locale}.lproj" / "Localizable.strings"
        existing = path.read_text(encoding="utf-8")
        missing = [(k, v) for k, v in pairs if f'"{k}"' not in existing]
        if not missing:
            print(f"{locale}: already present")
            continue
        with io.open(path, "a", encoding="utf-8", newline="") as handle:
            handle.write("\n")
            for key, value in missing:
                handle.write(f'"{key}" = "{value}";\n')
        print(f"{locale}: added {len(missing)} keys")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
