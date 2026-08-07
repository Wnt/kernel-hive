# templeos boot capture — automated-input prep

Status: **AUTHORED-UNTESTED**. The live shot showed the 640×480 HolyC terminal at
`T:/Home>`.

TempleOS runs from ISO/RAM and cold boot asks two blocking questions. The arm starts
capture, then `templeos-record-driver.sh` records framebuffer evidence and answers
no to both “install to hard drive” and “take tour”; no human input occurs. After a
further 15 s hold, ready means the main HolyC terminal and `T:/Home>` prompt are
visible. Reject a question, tour, or AutoComplete demo window.

The copied `state.qcow2` is only the vmstate store; array/scalar loadvm is suppressed
before boot. Audio is off. Canvas is 640×480/30 fps. The inherent HUD clock/caret
animate, so Tier 1 is intentionally avoided and promotion requires poster review.
