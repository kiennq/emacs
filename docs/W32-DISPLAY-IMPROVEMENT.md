# Windows Display Improvement Plan

This document outlines the plan to modernize Emacs display rendering on Windows
using Direct2D and related modern Windows APIs.

## Current State

### Existing Display Technologies

1. **GDI (Graphics Device Interface)** - Primary rendering backend
   - `src/w32term.c` (8,593 lines) - Main terminal/display code
   - Uses traditional Windows GDI calls (CreateSolidBrush, BitBlt, FillRect, etc.)
   - CPU-bound, no GPU acceleration for most operations
   - ~62 GDI drawing calls that need replacement

2. **DirectWrite** (`src/w32dwrite.c`, 1,365 lines) - Text rendering
   - Already GPU-accelerated for text
   - Available since Windows 7, enabled by default on Windows 8.1+
   - Uses Direct2D internally for color font support
   - Controlled via `w32-inhibit-dwrite` variable

3. **GDI+** (`src/w32image.c`, `w32gdiplus.h`) - Image handling
   - Used for smooth image scaling and format support
   - Some hardware acceleration when available

4. **Double Buffering** - Already implemented
   - `w32-disable-double-buffering` controls this
   - Reduces flicker during redisplay
   - Currently uses GDI memory DC + BitBlt

### Performance Bottlenecks

1. **GDI is CPU-bound** - Unlike Cairo on Linux which can use GPU
2. **Frequent GDI object creation/deletion** - Brushes, pens, DCs
3. **No batching of draw calls** - Each primitive is immediate
4. **BitBlt for scrolling** - Could be GPU-accelerated
5. **Window compositing** - DWM helps but Emacs doesn't use DirectComposition

## Proposed Architecture (Windows 10/11+)

### Target APIs

| API | Version | Purpose |
|-----|---------|---------|
| Direct2D | 1.3+ | GPU-accelerated 2D rendering |
| DirectWrite | 1.3+ | Text rendering (existing) |
| DXGI | 1.2+ | Flip model swap chains |
| D3D11 | 11.0+ | GPU device, shared surfaces |
| DirectComposition | 1.0+ | Hardware window compositing |

### Architecture Diagram

```
┌─────────────────────────────────────────────────┐
│              Emacs Redisplay Engine             │
│         (xdisp.c, dispnew.c, etc.)              │
├─────────────────────────────────────────────────┤
│              w32d2d.c (NEW)                     │
│    - D2D device context management              │
│    - Drawing primitive wrappers                 │
│    - Resource caching (brushes, bitmaps)        │
├──────────────────┬──────────────────────────────┤
│   Direct2D 1.3   │   DirectWrite 1.3 (existing) │
│   - FillRect     │   - Text shaping             │
│   - DrawBitmap   │   - Glyph rendering          │
│   - DrawLine     │   - Color fonts              │
├──────────────────┴──────────────────────────────┤
│         DXGI 1.2+ Swap Chain                    │
│    - Flip model (DXGI_SWAP_EFFECT_FLIP_*)       │
│    - Lowest latency, no tearing                 │
│    - Dirty rectangle support                    │
├─────────────────────────────────────────────────┤
│              D3D11 Device                       │
│    - Feature level 11_0                         │
│    - Shared with D2D via DXGI                   │
├─────────────────────────────────────────────────┤
│         GPU (Hardware Accelerated)              │
└─────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Infrastructure (2-3 weeks)

Create `src/w32d2d.c` and `src/w32d2d.h`:

1. **D3D11 Device Creation**
   ```c
   static ID3D11Device *d3d_device;
   static ID3D11DeviceContext *d3d_context;
   ```

2. **DXGI Swap Chain (per window)**
   ```c
   struct w32_d2d_surface {
     IDXGISwapChain1 *swap_chain;
     ID2D1DeviceContext *d2d_context;
     ID2D1Bitmap1 *target_bitmap;
   };
   ```

3. **D2D Device Context**
   ```c
   static ID2D1Factory1 *d2d_factory;
   static ID2D1Device *d2d_device;
   ```

4. **Initialization/Shutdown**
   ```c
   bool w32_d2d_init (void);
   void w32_d2d_shutdown (void);
   bool w32_d2d_create_surface (HWND hwnd, struct w32_d2d_surface *surface);
   void w32_d2d_destroy_surface (struct w32_d2d_surface *surface);
   ```

### Phase 2: Core Primitives (3-4 weeks)

Replace GDI calls with D2D equivalents:

| GDI Function | D2D Replacement |
|--------------|-----------------|
| `FillRect` | `ID2D1DeviceContext::FillRectangle` |
| `Rectangle` | `ID2D1DeviceContext::DrawRectangle` |
| `BitBlt` | `ID2D1DeviceContext::DrawBitmap` |
| `CreateSolidBrush` | `ID2D1DeviceContext::CreateSolidColorBrush` |
| `CreatePen` | `ID2D1StrokeStyle` + brush |
| `MoveToEx/LineTo` | `ID2D1DeviceContext::DrawLine` |
| `SelectObject` | D2D state is set per-call |

**Key wrapper functions:**
```c
void w32_d2d_fill_rect (struct w32_d2d_surface *s,
                        int x, int y, int w, int h,
                        COLORREF color);

void w32_d2d_draw_rect (struct w32_d2d_surface *s,
                        int x, int y, int w, int h,
                        COLORREF color, float stroke_width);

void w32_d2d_draw_line (struct w32_d2d_surface *s,
                        int x1, int y1, int x2, int y2,
                        COLORREF color, float stroke_width);

void w32_d2d_draw_bitmap (struct w32_d2d_surface *s,
                          ID2D1Bitmap *bitmap,
                          int dst_x, int dst_y, int dst_w, int dst_h,
                          int src_x, int src_y, int src_w, int src_h);
```

### Phase 3: Bitmap/Image Integration (2 weeks)

1. **HBITMAP to ID2D1Bitmap conversion**
   ```c
   ID2D1Bitmap *w32_d2d_bitmap_from_hbitmap (HBITMAP hbm);
   ```

2. **Integrate with GDI+ image loading**
   - Load via GDI+ → convert to D2D bitmap
   - Cache D2D bitmaps for frequently used images

3. **Fringe bitmaps**
   - Convert fringe_bmp array to D2D bitmaps
   - Use `DrawBitmap` with opacity for rendering

### Phase 4: Text Rendering Integration (1 week)

DirectWrite already works. Need to:

1. Connect DirectWrite to D2D device context
2. Use `ID2D1DeviceContext::DrawTextLayout` instead of GDI ExtTextOut
3. Ensure color emoji and ligatures work

### Phase 5: Scroll Optimization (1-2 weeks)

Replace `BitBlt` scrolling with D2D:

1. **Option A: DrawBitmap self-copy**
   - Copy portion of swap chain to itself
   - Fill exposed region

2. **Option B: Scroll the entire content**
   - Redraw visible portion only
   - Use dirty rectangles

3. **Option C: DirectComposition**
   - Use visual tree for scrolling content
   - GPU-composited scrolling

### Phase 6: Testing & Optimization (2-3 weeks)

1. **Benchmark suite**
   - Extend `test/manual/w32-perf-bench.el`
   - Compare GDI vs D2D performance

2. **Edge cases**
   - Multiple monitors with different DPI
   - Remote desktop (D2D falls back gracefully)
   - Older GPUs

3. **Fallback path**
   - Runtime detection of D2D availability
   - Fall back to GDI if D2D fails

## Code Changes Required

### Modified Files

| File | Changes |
|------|---------|
| `src/w32term.c` | Replace GDI calls with w32_d2d_* wrappers |
| `src/w32term.h` | Add D2D surface to frame output data |
| `src/w32fns.c` | Create D2D surface on window creation |
| `src/w32font.c` | Integrate with D2D text rendering |
| `configure.ac` | Add D2D detection and flags |

### New Files

| File | Purpose |
|------|---------|
| `src/w32d2d.c` | Direct2D implementation |
| `src/w32d2d.h` | Direct2D public interface |

### Build System

Add to `configure.ac`:
```m4
dnl Check for Direct2D (Windows 10+)
AC_CHECK_HEADERS([d2d1_1.h d3d11.h dxgi1_2.h],
  [HAVE_D2D=yes], [HAVE_D2D=no])
if test "$HAVE_D2D" = "yes"; then
  AC_DEFINE([USE_DIRECT2D], [1], [Define if using Direct2D])
  W32_LIBS="$W32_LIBS -ld2d1 -ld3d11 -ldxgi -ldwrite"
fi
```

## Expected Performance Gains

| Operation | Expected Improvement |
|-----------|---------------------|
| Rectangle fills | 50-100% faster |
| Scrolling | 30-50% faster |
| Image display | 40-60% faster |
| Overall redisplay | 30-50% faster |
| CPU usage during scroll | 50-70% reduction |

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| D2D not available | Runtime detection, GDI fallback |
| Driver bugs | Test on multiple GPU vendors |
| Memory usage increase | Pool/cache D2D resources |
| Breaking existing features | Comprehensive test suite |
| Remote desktop | D2D works, may fall back to software |

## Timeline

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Phase 1: Infrastructure | 2-3 weeks | 2-3 weeks |
| Phase 2: Core Primitives | 3-4 weeks | 5-7 weeks |
| Phase 3: Bitmap/Image | 2 weeks | 7-9 weeks |
| Phase 4: Text Integration | 1 week | 8-10 weeks |
| Phase 5: Scroll Optimization | 1-2 weeks | 9-12 weeks |
| Phase 6: Testing | 2-3 weeks | 11-15 weeks |

**Total: 11-15 weeks** for a single experienced developer.

## References

- [Direct2D Documentation](https://docs.microsoft.com/en-us/windows/win32/direct2d/direct2d-portal)
- [DXGI Flip Model](https://docs.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-flip-model)
- [DirectComposition](https://docs.microsoft.com/en-us/windows/win32/directcomp/directcomposition-portal)
- [Improving Performance with D2D](https://docs.microsoft.com/en-us/windows/win32/direct2d/improving-direct2d-performance)
- Existing implementation: `src/w32dwrite.c` (DirectWrite integration)
