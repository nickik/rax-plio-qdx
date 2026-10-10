
## Media injection for whole-machine integration

`mkQDXBCardWithMedia(QDXBMediaIfc media)` preserves the physical card, QIC,
QDX-A and QDX-B endpoint paths while allowing the machine to supply storage.
The legacy `mkQDXBCard` constructor still uses `mkQDXBFakeMedia` for existing
unit fixtures. LightingChips' whole-machine top uses its image-backed hardware
media in slot 0; this changes no PLIO/QDX binary layout or bus authority.

Injected media supplies namespace validity/count, block size/count, word storage
and flush behavior through `QDXBMediaIfc`. The endpoint uses that geometry for
IDENTIFY, namespace validation, LBA bounds and payload size. The current staging
store supports blocks up to 1 KiB; the standalone Lighting machine uses one
namespace with 64 blocks of 512 bytes. No QDX descriptor layout changes.
