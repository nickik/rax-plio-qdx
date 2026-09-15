package QDXAQicPort;

import QICInterfaces::*;

// Current chip-boundary abstraction between the QIC and QDX-A.
//
// QdxAQicToChip is what the QIC drives toward the local device.
// QdxAChipToQic is what QDX-A drives back toward the QIC.
//
// A later PCB wrapper lowers this exact semantic contract onto QLI-16 pins.
typedef QliOut QdxAQicToChip;
typedef QliIn  QdxAChipToQic;

function QdxAChipToQic qdxAChipToQicDefault();
    return qliInDefault();
endfunction

endpackage
