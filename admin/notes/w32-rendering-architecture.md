# Windows Rendering Architecture — GDI vs D3D11/D2D

This document describes the rendering pipeline on Windows, the ongoing
D3D11/DXGI/Direct2D GPU-accelerated rendering work, and known issues.

## Table of Contents

1. [Rendering Modes](#rendering-modes)
2. [Redisplay Cycle](#redisplay-cycle)
3. [Drawing Pipeline](#drawing-pipeline)
4. [Text Rendering Paths](#text-rendering-paths)
5. [Cursor Drawing](#cursor-drawing)
6. [Fill / Clear Operations](#fill--clear-operations)
7. [Image / Bitmap Drawing](#image--bitmap-drawing)
8. [DC Acquisition](#dc-acquisition)
9. [Back Buffer & Present](#back-buffer--present)
10. [Swap Chain Configuration](#swap-chain-configuration)
11. [Present Timing Diagram](#present-timing-diagram)
12. [Known Issues & Root Causes](#known-issues--root-causes)
13. [GDI Operations Not Yet Migrated to D2D](#gdi-operations-not-yet-migrated-to-d2d)
14. [File Map](#file-map)

---

## Rendering Modes

Emacs on Windows has three rendering paths:

```
┌─────────────────────────────────────────────────────────┐
│                    Rendering Modes                       │
├───────────────┬───────────────────┬─────────────────────┤
│  GDI (legacy) │  D3D + Direct DC  │  Pure D2D (target)  │
├───────────────┼───────────────────┼─────────────────────┤
│ paint_buffer  │ d3d_direct_dc=1   │ d3d_direct_dc=0     │
│ = HBITMAP     │ paint_dc = swap   │ paint_dc = NULL      │
│ BitBlt to     │ chain surface DC  │ D2D target on swap   │
│ window on     │ GDI draws to swap │ chain; D2D fills &   │
│ present       │ chain directly    │ DirectWrite text     │
│               │ (DISABLED)        │ into back buffer     │
└───────────────┴───────────────────┴─────────────────────┘
```

### Pure D2D mode detection

```c
output->use_d3d
  && output->dxgi_swap_chain
  && output->d2d_context
  && output->d2d_target
  && !output->d3d_direct_dc
```

---

## Redisplay Cycle

Emacs redraws frames through a series of terminal hooks.  The
redisplay engine in xdisp.c calls these hooks on the frame's terminal:

```
 xdisp.c redisplay
    │
    ▼
 ┌──────────────────────────────────────────────────────────┐
 │  update_begin_hook  →  w32_update_begin()    [line 968]  │
 │    • Pure D2D: w32_d2d_begin_frame()                     │
 │    • Optional full-frame clear (only if f->garbaged)     │
 │    • Sets mouse_face_defer = true                        │
 └──────────────────────────┬───────────────────────────────┘
                            │
              ┌─────────────┴─────────────┐
              │   FOR EACH WINDOW IN F:   │
              │                           │
              │  • draw glyph strings     │
              │  • draw fringes           │
              │  • scroll_run             │
              │  • erase_phys_cursor      │
              │  • draw new cursor        │
              │                           │
              └─────────────┬─────────────┘
                            │
 ┌──────────────────────────▼───────────────────────────────┐
 │  update_end_hook  →  w32_update_end()       [line 1118]  │
 │    • *** FIRES PER WINDOW, NOT PER FRAME ***             │
 │    • Pure D2D: present if dirty && !blocked              │
 │    • paint_buffer_dirty cleared after first present       │
 │    • Subsequent window update_end calls are no-ops       │
 │    • *** BUG: presents BEFORE all windows are done ***   │
 └──────────────────────────┬───────────────────────────────┘
                            │
 ┌──────────────────────────▼───────────────────────────────┐
 │  frame_up_to_date_hook → w32_frame_up_to_date [ln 1150]  │
 │    • Fires ONCE per frame after all windows updated      │
 │    • Pure D2D: currently early-returns (no present)      │
 │    • GDI: present if dirty && !blocked                   │
 │    • *** THIS is the correct present site for D2D ***    │
 └──────────────────────────┬───────────────────────────────┘
                            │
 ┌──────────────────────────▼───────────────────────────────┐
 │  buffer_flipping_unblocked_hook             [line 1172]   │
 │    • Fires when buffer_flipping_blocked_p() → false      │
 │    • Rescues deferred presents                           │
 │    • Pure D2D: currently early-returns                   │
 └──────────────────────────────────────────────────────────┘
```

### Additional present sites

```
w32_flip_buffers_if_dirty()                     [line 1195]
  Called from minibuf.c to force present.
  Pure D2D: currently early-returns.

w32_read_socket()                               [line 5753]
  Event loop.  Has batch-flush logic for pure D2D:
  After processing all messages, if a pure D2D frame is
  dirty and not blocked, presents once (lines 7097-7117).
```

---

## Drawing Pipeline

### Glyph string drawing — main dispatcher

```
w32_draw_glyph_string()                         [line 3251]
  │
  ├─ CHAR_GLYPH / COMPOSITE_GLYPH:
  │    ├─ w32_draw_glyph_string_background()    [line 1749]
  │    │    Uses w32_fill_area → w32_fill_rect → D2D fill
  │    │
  │    └─ w32_draw_glyph_string_foreground()    [line 1794]
  │         Calls font->driver->draw:
  │           ├─ w32_dwrite_draw()   [DirectWrite/D2D]
  │           └─ w32font_draw()      [GDI ExtTextOut]
  │
  ├─ IMAGE_GLYPH:
  │    └─ w32_draw_image_glyph_string()         [line 2940]
  │         *** Uses BitBlt to window DC — NOT in D2D ***
  │
  ├─ STRETCH_GLYPH:
  │    └─ w32_draw_stretch_glyph_string()       [line 3069]
  │         Uses w32_fill_area → D2D fill ✓
  │
  ├─ GLYPHLESS_GLYPH:
  │    └─ w32_draw_glyphless_glyph_string_fg()  [line 1945]
  │
  ├─ Box drawing (relief, borders):
  │    └─ w32_draw_glyph_string_box()           [line 2318]
  │         Uses w32_fill_area → D2D fill ✓
  │
  └─ Fringe bitmaps:
       └─ w32_draw_fringe_bitmap()              [line 1259]
            *** Uses BitBlt to window DC — NOT in D2D ***
```

---

## Text Rendering Paths

```
font->driver->draw
  │
  ├── DirectWrite path (w32dwrite.c)
  │     w32_dwrite_draw()                       [line 1264]
  │       │
  │       ├── Pure D2D mode:
  │       │     w32_d2d_draw_glyphs_dc()        [line 1330]
  │       │     Draws directly into D2D back buffer ✓
  │       │
  │       ├── HDC mode:
  │       │     w32_d2d_draw_glyphs()           [line 1338]
  │       │     Draws via HDC (may be window DC) ✗
  │       │
  │       └── GDI fallback:
  │             DrawGlyphRun via HDC             [line 1443]
  │             Draws to window DC ✗
  │
  └── GDI font path (w32font.c)
        w32font_draw()                          [line  634]
          ExtTextOut(s->hdc, ...)
          Draws to window DC ✗
```

**Status**: Text rendering works correctly in pure D2D mode when
DirectWrite is active (which is the default on modern Windows).
GDI font fallback draws to the wrong surface.

---

## Cursor Drawing

```
display_and_set_cursor()          (xdisp.c:34727)
  │
  ├── erase_phys_cursor()         (xdisp.c:34592)
  │     Redraws glyph at old cursor position.
  │     Calls draw_phys_cursor_glyph(w, row, DRAW_NORMAL_TEXT)
  │       → w32_draw_glyph_string → full drawing pipeline
  │       In pure D2D: background via D2D fill ✓
  │                    text via DirectWrite D2D ✓
  │                    images via BitBlt ✗
  │
  └── w32_draw_window_cursor()    (w32term.c:~7400)
        │
        ├── FILLED_BOX:
        │     draw_phys_cursor_glyph(w, row, DRAW_CURSOR)
        │     Full redraw with cursor face
        │
        ├── HOLLOW_BOX:
        │     w32_draw_hollow_cursor()          [line 7228]
        │     Pure D2D: 4x w32_d2d_fill_rect_dc ✓
        │     GDI: FrameRect via window DC
        │
        ├── BAR_CURSOR:
        │     w32_draw_bar_cursor()             [line 7275]
        │     Pure D2D: w32_d2d_fill_rect_dc ✓
        │     GDI: w32_fill_area → w32_fill_rect
        │
        └── HBAR_CURSOR:
              w32_draw_bar_cursor(HBAR_CURSOR)
              Same as BAR_CURSOR
```

---

## Fill / Clear Operations

```
w32_fill_area (macro)             (w32term.h:731)
  │
  └── w32_fill_rect()             (w32term.c:815)
        │
        ├── Pure D2D mode:
        │     w32_d2d_fill_rect_dc()            [line 826]
        │     Draws directly into D2D back buffer ✓
        │
        ├── D2D available (non-pure):
        │     w32_d2d_fill_rect(hdc, ...)       [line 840]
        │     Draws via HDC
        │
        └── GDI fallback:
              FillRect(hdc, ...)                [line 844]
              Draws to window DC

w32_clear_frame_area()            (w32term.c:~7373)
  Uses get_frame_dc → w32_clear_area → w32_fill_area
  Pure D2D: fill goes to D2D ✓ but DC goes to window ✗
```

---

## Image / Bitmap Drawing

**ALL image drawing uses BitBlt to the window DC.**
This is completely broken in pure D2D mode.

```
w32_draw_image_glyph_string()     (w32term.c:2940)
  Uses: BitBlt, CreateCompatibleDC, SelectObject
  All operate on window DC from get_frame_dc ✗

w32_draw_fringe_bitmap()          (w32term.c:1259)
  Uses: BitBlt for fringe bitmaps
  All operate on window DC ✗

w32_scroll_run()                  (w32term.c:3608)
  Uses: BitBlt for scrolling
  Operates on window DC ✗

BitBlt call sites in w32term.c:
  Line  480: w32_show_back_buffer (GDI present path — OK)
  Line 1341: w32_draw_fringe_bitmap ✗
  Line 1343: w32_draw_fringe_bitmap ✗
  Line 1345: w32_draw_fringe_bitmap ✗
  Line 1359: w32_draw_fringe_bitmap ✗
  Line 2503: w32_draw_image_glyph_string ✗
  Line 2505: w32_draw_image_glyph_string ✗
  Line 2507: w32_draw_image_glyph_string ✗
  Line 2549: w32_draw_image_glyph_string ✗
  Line 2862: image related ✗
  Line 2864: image related ✗
  Line 2866: image related ✗
  Line 2877: image related ✗
  Line 3047: composite glyph bg ✗
  Line 3608: w32_scroll_run ✗
  Line 3775: scroll related ✗
```

---

## DC Acquisition

```
get_frame_dc()                    (w32xfns.c:180)
  │
  ├── Pure D2D mode (use_d3d && !d3d_direct_dc):
  │     Returns GetDC(hwnd) — the WINDOW DC
  │     Sets paint_buffer = (HBITMAP)1 sentinel
  │     Sets paint_buffer_dirty = 1
  │     *** THIS IS THE ROOT PROBLEM ***
  │     All GDI ops through this DC go to the window
  │     surface, not the D2D swap chain back buffer.
  │
  ├── D3D direct DC mode (d3d_direct_dc=1):
  │     paint_dc = swap chain surface DC
  │     Returns paint_dc (correct surface)
  │
  └── GDI mode:
        Creates HBITMAP back buffer, paint_dc = compatible DC
        Returns paint_dc

release_frame_dc()                (w32xfns.c:~368)
  If hdc != paint_dc → ReleaseDC
  If hdc == paint_dc → no-op (keeps DC alive)
```

---

## Back Buffer & Present

```
w32_show_back_buffer()            (w32term.c:398)
  │
  ├── Pure D2D mode:
  │     1. w32_d2d_end_frame() if d2d_drawing
  │     2. w32_d2d_present(output, false)
  │     3. Clear paint_buffer_dirty
  │     Present shows swap chain back buffer contents.
  │
  ├── Direct DC mode (DISABLED):
  │     Would release surface DC and present.
  │
  └── GDI mode:
        BitBlt from paint_dc (bitmap) to window DC.
        Clear paint_buffer_dirty.


w32_d2d_begin_frame()             (w32d3d.c:1718)
  ID2D1DeviceContext::BeginDraw
  Sets d2d_drawing = 1

w32_d2d_end_frame()               (w32d3d.c:~1740)
  ID2D1DeviceContext::EndDraw
  Sets d2d_drawing = 0

w32_d2d_present()                 (w32d3d.c:579)
  IDXGISwapChain1::Present
  sync_interval=1 (flip-sequential, no tearing)
```

---

## Swap Chain Configuration

```
w32_d3d_create_swap_chain()       (w32d3d.c:~425)

  Current: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL
    • BufferCount = 2
    • Format = B8G8R8A8_UNORM
    • Scaling = NONE
    • AlphaMode = IGNORE
    • allow_tearing = 0

  FLIP_SEQUENTIAL preserves back buffer contents between
  presents.  This is needed because Emacs redraws
  incrementally (only changed regions each cycle).

  Previous attempt with FLIP_DISCARD caused stale pixels
  (cursor trails) because back buffer content is undefined
  after present — requires full redraw each cycle which
  Emacs doesn't do.
```

---

## Present Timing Diagram

### Current (BUGGY) — update_end presents per-window

```
Time ──────────────────────────────────────────────────►

update_begin
  │ D2D BeginDraw
  │
  ├── Window 1 (main text area):
  │     draw background fills (D2D) ✓
  │     draw text (DirectWrite D2D) ✓
  │     draw fringes (BitBlt window DC) ✗
  │     erase old cursor (D2D) ✓
  │     draw new cursor (D2D) ✓
  │
  │  update_end (Window 1):
  │    *** PRESENT *** ← shows Window 1 content
  │    paint_buffer_dirty = 0
  │
  ├── Window 2 (minibuffer):
  │     draw text (D2D) ✓
  │     (cursor changes here too sometimes)
  │
  │  update_end (Window 2):
  │    paint_buffer_dirty already 0 → no-op
  │
frame_up_to_date:
  Pure D2D early-return → no present

RESULT: Window 2 changes not presented until next cycle.
        If cursor was in Window 2, trail appears.
```

### Desired — frame_up_to_date presents once per frame

```
Time ──────────────────────────────────────────────────►

update_begin
  │ D2D BeginDraw
  │
  ├── Window 1: draw everything (D2D)
  │  update_end (Window 1): NO present, just bookkeeping
  │
  ├── Window 2: draw everything (D2D)
  │  update_end (Window 2): NO present, just bookkeeping
  │
frame_up_to_date:
  *** SINGLE PRESENT *** ← shows ALL windows
  paint_buffer_dirty = 0

buffer_flipping_unblocked_hook:
  Rescue if frame_up_to_date was blocked.

RESULT: All content from all windows in single present.
        No cursor trails from partial presents.
```

---

## Known Issues & Root Causes

### 1. Cursor Trails

**Symptom**: Ghost cursor bars visible at old positions.

**Root Cause (Primary)**: `update_end` presents after the first
window is drawn.  If cursor erase/redraw happens in a subsequent
window or later in the same window, the present shows stale cursor
pixels.

**Root Cause (Secondary)**: With FLIP_DISCARD (now reverted), the
back buffer content is undefined after present.  Incremental
redraws leave most of the buffer uninitialized.

**Fix Direction**: Move pure-D2D present from `update_end` to
`frame_up_to_date`.  Must also restore `unblocked_hook` as a
rescue for when `buffer_flipping_blocked_p()` is true during
`frame_up_to_date`.

### 2. Popup / Completion Window Artifacts

**Symptom**: Garbled text with red/green color artifacts in
completion popups.

**Root Cause**: Child frames / popup windows may go through a
different rendering path.  The popup window's own redisplay cycle
may mix GDI and D2D drawing.

### 3. GDI Operations Drawing to Wrong Surface

**Symptom**: Various visual glitches, missing content.

**Root Cause**: `get_frame_dc()` returns the WINDOW DC in pure D2D
mode.  Any GDI operation that doesn't go through `w32_fill_rect`
draws to the window surface (which is behind the swap chain).

**Affected Operations**:
- BitBlt (images, fringes, scrolling)
- FrameRect (hollow cursor GDI path)
- ExtTextOut (GDI font fallback)
- Various SelectObject/CreateCompatibleDC patterns

### 4. Present Storms (Previously Observed)

**Symptom**: Extremely slow typing.

**Root Cause**: Multiple present sites firing per-event or
per-window.  The `unblocked_hook` was observed firing 110 times
in a short session.

**Fix**: Suppress duplicate present paths.  Only one present site
should be active for pure D2D.

---

## GDI Operations Not Yet Migrated to D2D

These operations still use GDI HDC and draw to the window surface.
They need D2D equivalents for correct rendering in pure D2D mode:

| Operation | Location | D2D Equivalent Needed |
|-----------|----------|----------------------|
| BitBlt (images) | w32term.c:2503-2549 | ID2D1DeviceContext::DrawBitmap |
| BitBlt (fringes) | w32term.c:1341-1359 | D2D bitmap from fringe data |
| BitBlt (scroll) | w32term.c:3608 | CopyFromBitmap or re-render |
| FrameRect | w32term.c:7279 (hollow cursor) | D2D fill rects (DONE) |
| ExtTextOut | w32font.c:634 | DirectWrite (already default) |
| CreateCompatibleDC | Various | D2D bitmap targets |
| Rectangle | w32term.c:785 | D2D DrawRectangle |

---

## File Map

| File | Purpose |
|------|---------|
| `src/w32term.c` | Main W32 terminal — redisplay hooks, drawing, cursor, present |
| `src/w32term.h` | Shared types, `w32_output` struct, macros |
| `src/w32xfns.c` | DC acquisition (`get_frame_dc`/`release_frame_dc`) |
| `src/w32font.c` | GDI font driver (fallback text rendering) |
| `src/w32font.h` | Font driver declarations |
| `src/w32dwrite.c` | DirectWrite font driver + D2D text rendering |
| `src/w32d3d.c` | D3D11/DXGI/D2D initialization, swap chain, fill, present |
| `src/w32d3d.h` | D3D/D2D function declarations |
| `src/w32.c` | Core Windows utilities |
| `src/w32proc.c` | Process/subprocess handling |
| `src/xdisp.c` | Cross-platform redisplay engine (cursor logic) |
| `src/dispextern.h` | Display-related declarations |
| `src/emacs.c` | D3D initialization call site |

---

## Implementation Priority

1. **P0 — Fix present timing**: Move present from `update_end` to
   `frame_up_to_date` with `unblocked_hook` rescue.  This fixes
   cursor trails.

2. **P1 — Verify text path**: Confirm DirectWrite is always used
   (not GDI font fallback) so text goes through D2D.

3. **P2 — Migrate BitBlt to D2D**: Images, fringes, scrolling.
   These are currently broken in pure D2D mode.

4. **P3 — Audit all GDI operations**: Ensure nothing draws to the
   window DC in pure D2D mode.
