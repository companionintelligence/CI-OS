# Provenance of the stick images

> **Private & Confidential. Property of Lifescope Inc. Do not distribute.**

Both files are copied, byte for byte, from the brand canon, CI-Common (`companionintelligence/CI-Common`). They are used as
supplied: not edited, re-encoded or re-coloured here.

| File | CI-Common path | Added by | sha256 |
|---|---|---|---|
| `usb-closed.webp` | `generated/ads/cutouts/usb-closed.webp` | #332 (commit `04655601`, 2026-10-15) | `3598ddf31354351ef401d83377c34159880508c5e2d01eed6c737b6f80fa03a3` |
| `usb-open-stick.webp` | `generated/ads/cutouts/usb-open-stick.webp` | #332 (commit `04655601`, 2026-10-15) | `e7372474d1dad276456b0e953a627c885826e303e1b291e4e7bd9326aabbb0ea` |

Checked against CI-Common at `d9090734b4269a4c75a4ec9d0fe9a175b77e4915` (`origin/main`, 2026-10-19): both blobs are identical to these files.

They are transparent cutouts (RGBA, 942 x 314 and 890 x 302), so they sit on the film's dark ground without a white box. The sibling
files in the same directory, `usb-open-cap.webp` and the white-background photographs under `generated/ads/photos/usb-installer/`,
are not used.

What the film claims from them: that Companion OS comes on a stick that looks like this. It does not claim that the stick in the
pictures was the one in the recording: the recording installed from an image file in a virtual machine.

To refresh them, copy from a newer CI-Common, update the table above and the date, and re-run the film.
