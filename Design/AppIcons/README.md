# VayuSetu icons

Hanuman's golden gada is the central emblem, surrounded by blue wind representing the VayuSetu wind identity. Midnight navy matches the app. The reference uses a deity's traditional weapon rather than a deity portrait.

Generated using the built-in image-generation tool. Final prompt: a bold golden Hanuman gada with restrained Indian temple ornament, blue wind sweep and navy background, no deity portrait or typography. macOS variant preserves this artwork in a rounded square with transparent margins.

Run `python3 Design/AppIcons/scripts/package.py` from the project root to rebuild native resources. iOS uses opaque square assets; macOS uses a dedicated transparent tile and ten ICNS representations from 16 to 1024 pixels. The previous wind icon is retained in `previous`.

Source resources are updated. Previously signed app/IPA/DMG artifacts retain their previous icon until rebuilt; packaging does not modify their signatures.

Verification: all 19 iOS slots have exact required pixel dimensions; iOS 1024 master is opaque. ICNS was extracted and its 16px and 1024px representations inspected; the macOS master has alpha with transparent outer corners. ZIP integrity verified.

Brand meaning: the gada suggests strength and protection; flowing blue wind expresses Vayu and the bridge between VPN tunneling and encrypted DNS. These are visual meanings, not claims of independently verified security.
