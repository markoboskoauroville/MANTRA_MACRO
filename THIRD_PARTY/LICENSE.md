# Third-party code

## Rectangle (MIT)

app/WinMgr.swift is ported from Rectangle, https://github.com/rxhanson/Rectangle (Copyright (c) 2019-2026 Ryan Hanson,
based on Spectacle, Copyright (c) 2017 Eric Czarny). Ported ideas and code: the Accessibility window element and its frame
adjustment (size, position, size again; AXEnhancedUserInterface switched off while the window moves), the NSScreen and
Accessibility coordinate flip, the visible frame of a screen (menu bar and Dock), the window calculations (halves, thirds,
two thirds, quarters, maximize, almost maximize, center, orientation aware thirds) and the next/previous display transfer.
The full licence text is in THIRD_PARTY/Rectangle-LICENSE.txt and stays with every copy of the source.
