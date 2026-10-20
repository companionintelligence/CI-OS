# Provenance of the screenshot plates

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

Written by `video/tools/make-plates.py` from `video/tools/plates.json`; `--verify` reads the table below. Do not edit by hand.

Every plate is a frame of one recording of the first run in a virtual machine, not a mock-up. **[V]** for what the frames show; nothing
here is a run on real hardware.

| | |
|---|---|
| Taken | 2026-10-19 |
| Image | `companion-os-1.0-arm64.iso, built from 82e9335` |
| Image sha256 | `e43e2066713306494abe541faff6ab20f3ec56c8676ac61b1a85bc05252e86ac` |
| Machine | QEMU virt with HVF on Apple silicon, virtio-gpu 1920x1080, 8 GiB, 6 CPUs |
| Choices made | English (United Kingdom), keyboard English (UK), time zone London |
| Run record | `docs/evidence/2026-10-19-ubuntu-arm64-82e9335-video-run/` |
| Plate size | 1920 x 1080 |

**Covered** is a redaction: the installer prints a one-time password for the throw-away VM account, and the rectangle is a solid bar
drawn over those characters before the file was written. Rectangles are `[x0, y0, x1, y1]` in plate pixels.

| plate | source in the run | source sha256 | covered | plate sha256 | what it shows |
|---|---|---|---|---|---|
| grub | `frames/f-1792455257.png` | `de6de6733adaea42f3c7dd6b557926accbbbc6eedbb55d6f44cecca3994ff2f4` | none | `75f501fc93a449a80bb221651793ae08fcaea40b9aa64b84b27ac6b0aacaa11e` | the boot menu, Install Companion OS (automatic) highlighted |
| one-click-dialog | `confirm-en.png` | `d1fd7c1b1e0f548f1f53b23ef7cc495a7a620787138abcd719c9fba021bcc115` | `[668,529,882,550]` | `2e835aae71b0d6f8edd4806e2ef684bed06f20513b4af9931536413695cc842a` | the one-click installer's question with the English (United States) defaults |
| region-menu | `menu0.png` | `8e4ea80612aee24499a9eae0e24169f799baaf4ff9443d0b211e3495568be882` | none | `a8bb348ba1e06b2664d28841091779d6a55771f6367f07b39b27f90059c0ffc4` | language, keyboard and time zone before the change (English (United States)) |
| region-search | `lang-search.png` | `ac78d34a21996348671a597f7b1e19713a9c9c2c00ffa3a1650d85665f860914` | none | `425a561432b68bbaff089eefbf013ec38f22b2b0a79c022135c183d75f5b87e8` | the language list narrowed by typing United Kingdom |
| region-done | `menu1.png` | `68e0567cfcd887dadc511024adf40324b983cef6c7b29716e13f9e7dfca2eb4d` | none | `c0aada2336cfcb933aaf86088c4f550f7a0afa5023ac41b1578006240c235726` | language, keyboard and time zone after the change (English (United Kingdom), London) |
| confirm-uk | `confirm-uk.png` | `0b940c90972ba16e46387ff99ca34803cee5c2b48aa781f07faf42eeb5b890d9` | `[701,529,915,550]` | `a39122282434804665f6cf7c9ef1392e6cd225bf66dd5403b3ecef4bda4f83e7` | the one-click installer's question naming the English (United Kingdom) choice |
| installing | `progress0.png` | `8def7680d719937a81eadf400ee26628aaeeb33f73dad5984dc46498ade32fd4` | `[866,545,1009,564]` | `664be1e8beddfb6743ba646c34d055a52c556a159a438873b04ad146f2a2a87b` | the installer's progress window |
| greeter | `greeter.png` | `b311d1e83166fc5c1a2ed07d636ad2a9dbd759c6dc0b789acfb264dcf525b63a` | none | `eff39a1d26aa0ac3cde4b4f3fe41058c7149a07ce626db1f430651e7f3725918` | the sign-in screen after the first start, English (United Kingdom) date |
| greeter-change | `greeter-change.png` | `6bb6ec4a2faeb75ded81d4b5d81d396ba2e22648ffc3ed4f2d610915ad7791b4` | none | `d462acd07a56405b4760d5ba180d3aa22015d1cec906c8d9e4a2911b1406cfbe` | the forced password change at the first sign-in (empty field) |
| desktop-welcome | `after-login.png` | `24cb4a3e91c8b7d53990e36209ba019a6722e62ceffbfaf1a30a3ddef0878b78` | none | `017f524f8cf0feb8866324715c6e63ac7eb6d6ec9bd2952ddae4ac46e4eac50d` | the first desktop, the getting started page open |
| banner-waiting | `frames/f-1792456745.png` | `395b02c2e4a37d9653f1b376fe213ffc0dc8fbb641a071865d548d1ac0c91721` | none | `fe81089ea8ae62ef86715a0240c502166d3759a699000a815f166044bb7f67d6` | the waiting banner: Companion OS is getting ready |
| banner-step5 | `frames/f-1792456905.png` | `1ebf045e945abe76e4068b7e77d1a4dcce7dca9d5e05648935c1ee2e966d4a86` | none | `0d4dbb8bbba1c335c8e928fb64003baff586c87084375b21031390ef437995a8` | the progress banner: step 5 of 7, Downloading the AI models |
| banner-ready | `frames/f-1792456975.png` | `d8b34eab2e678ac1126099c445d52c67c442a2a5f76d24cec5b9e971c092c08a` | none | `af09bc3d9f80a9a4788bdc089edfda9d5fa8f4ce2b3b2aa77cc5fd1bcf0a134b` | the ready banner: Companion OS is ready |
| desktop-ready | `now.png` | `b664eb51add040aee268a3e7ddb45fbeccc89807b5904e1a8a28b73904f75cd6` | none | `b103c6035919b07fd7a887ea22cef03439e74565d0da8872789c20e8e810b01a` | the desktop after setup finished, before Companion Hub is opened |
| hub-pairing | `hub2.png` | `2234921d94f64e9e7c3a68b1866330acb8a7e2c0e448aad52525a75adc373ef2` | none | `e65217fee175f09e749500df6d0d67ddfc7cf354da0c75c7c4f719464b08cf88` | Companion Hub opened from the first dock icon, at its pairing page |
