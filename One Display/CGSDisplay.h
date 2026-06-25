//
//  CGSDisplay.h
//  One Display
//
//  Bridging header exposing the private SkyLight display-enable API.
//
//  `CGSConfigureDisplayEnabled` is NOT part of the public SDK. It is the only
//  known mechanism to *truly* disable a display (including the built-in panel)
//  while the lid is open. Using it means this app can never be sandboxed or
//  shipped on the App Store — acceptable for a personal utility.
//

#ifndef CGSDisplay_h
#define CGSDisplay_h

#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config,
                                          CGDirectDisplayID display,
                                          bool enabled);

#endif /* CGSDisplay_h */
