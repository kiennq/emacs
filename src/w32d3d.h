/* Direct3D 11 and Direct2D GPU-accelerated rendering for Emacs on
Windows.

This module provides two layers of GPU acceleration:

1. D3D11/DXGI swap chain -- replaces GDI BitBlt for frame
presentation. All existing GDI drawing code continues to work
unchanged through IDXGISurface1::GetDC(), which provides a
GDI-compatible HDC backed by the GPU swap chain surface.

2. Direct2D DC render target -- provides hardware-accelerated 2D
   drawing (text, rectangles) bound to any GDI HDC.  This eliminates
   the double-BitBlt overhead in the DirectWrite text rendering path.

Both layers are loaded at runtime via LoadLibrary/GetProcAddress so
that Emacs still starts on systems without D3D11 or D2D (graceful
fallback to GDI double buffering and GDI-based DirectWrite).  */

#ifndef EMACS_W32D3D_H
#define EMACS_W32D3D_H

#include <windows.h>

#ifdef HAVE_NTGUI

struct w32_output;

/* ----------------------------------------------------------------
   D3D11 / DXGI swap chain layer
   ---------------------------------------------------------------- */

/* Initialize the D3D11 subsystem.  Call once at startup.
   Returns true on success, false if D3D11 is unavailable.  */
extern bool w32_d3d_init (void);

/* Release all global D3D11 resources.  Call at shutdown.  */
extern void w32_d3d_shutdown (void);

/* Create a DXGI swap chain for the given HWND.
   Returns true on success.  On failure, the frame should
   fall back to GDI double buffering.  */
extern bool w32_d3d_create_swap_chain (struct w32_output *output,
				       HWND hwnd, int width,
				       int height);

/* Release the swap chain and associated resources.  */
extern void w32_d3d_release_swap_chain (struct w32_output *output);

/* Acquire a GDI-compatible HDC from the swap chain back buffer.
   The caller must call w32_d3d_release_dc() when done drawing.
   Returns NULL on failure.  */
extern HDC w32_d3d_acquire_dc (struct w32_output *output);

/* Release the GDI-compatible HDC back to the swap chain surface.  */
extern void w32_d3d_release_dc (struct w32_output *output);

/* Present the swap chain back buffer to the screen.  */
extern void w32_d3d_present (struct w32_output *output);

/* Resize the swap chain buffers to match new dimensions.
   Call when the frame is resized.  Returns true on success.  */
extern bool w32_d3d_resize (struct w32_output *output, int width,
			    int height);

/* Return true if D3D11 is initialized and available.  */
extern bool w32_d3d_available_p (void);

/* Disable D3D for a frame: clear all D3D state fields and release
   the swap chain.  Use when D3D operations fail and we need to
   fall back to GDI.  */
extern void w32_d3d_disable (struct w32_output *output);

/* ----------------------------------------------------------------
   Direct2D DC render target layer
   ---------------------------------------------------------------- */

/* Return true if the D2D drawing functions are available.  */
extern bool w32_d2d_available_p (void);

/* Shut down D2D: release factory, render target, and DLL.  */
extern void w32_d2d_shutdown (void);

/* Draw a glyph run using Direct2D, bound to the given HDC.
   HDC is the target device context (e.g., paint_dc).
   X, Y are the baseline origin (Y is the TOP of the glyph area,
   FONT_ASCENT is added internally to get baseline position).
   FONT_FACE is the IDWriteFontFace* for the font.
   FONT_SIZE is the em size in DIPs.
   INDICES is an array of glyph indices.
   ADVANCES is an array of glyph advance widths.
   LEN is the number of glyphs.
   COLOR is the text foreground color as COLORREF.
   AREA_X, AREA_Y, AREA_W, AREA_H define the clipping/bind region.
   Returns true on success, false if D2D is unavailable or fails.  */
extern bool w32_d2d_draw_glyphs (HDC hdc, int x, int y,
				 void *font_face, float font_size,
				 const unsigned short *indices,
				 const float *advances, int len,
				 COLORREF color, int area_x,
				 int area_y, int area_w, int area_h);

/* Fill a rectangle using Direct2D, bound to the given HDC.
   Returns true on success, false to fall back to GDI FillRect.  */
extern bool w32_d2d_fill_rect (HDC hdc, int x, int y, int w, int h,
			       COLORREF color);

/* Draw a glyph run using a Direct2D device context for OUTPUT.
   Returns true on success, false if the D2D context is unavailable
   or the draw fails.  */
extern bool w32_d2d_draw_glyphs_dc (
  struct w32_output *output, int x, int y, void *font_face,
  float font_size, const unsigned short *indices,
  const float *advances, int len, COLORREF color, int area_x,
  int area_y, int area_w, int area_h);

/* Fill a rectangle using a Direct2D device context for OUTPUT.
   Returns true on success, false if the D2D context is unavailable
   or the draw fails.  */
extern bool w32_d2d_fill_rect_dc (struct w32_output *output, int x,
				  int y, int w, int h,
				  COLORREF color);

/* Draw a rectangle using a Direct2D device context for OUTPUT.
   FOREGROUND and BACKGROUND are COLORREF values for stroke and fill.
 */
extern bool w32_d2d_draw_rect_dc (struct w32_output *output, int x,
				  int y, int w, int h,
				  COLORREF foreground,
				  COLORREF background);

/* Draw a polyline using a Direct2D device context for OUTPUT.
   POINTS has COUNT entries.  THICKNESS is the stroke width in DIPs.
   The clip rectangle is applied when CLIP_W and CLIP_H are positive.
 */
extern bool w32_d2d_draw_polyline_dc (struct w32_output *output,
				      const POINT *points, int count,
				      COLORREF color, float thickness,
				      int clip_x, int clip_y,
				      int clip_w, int clip_h);

/* Draw an image bitmap in a Direct2D device context for OUTPUT.
   PIXMAP and MASK are source bitmaps (MASK may be NULL).
   SRC_* define the source rectangle in PIXMAP coordinates.
   DST_* define destination rectangle on the target.
   SMOOTHING selects linear interpolation when non-zero.
   CLIP_* define an optional clip rectangle (ignored if width/height
   are non-positive).  */
extern bool
w32_d2d_draw_bitmap_dc (struct w32_output *output, HBITMAP pixmap,
			HBITMAP mask, int src_x, int src_y, int src_w,
			int src_h, int dst_x, int dst_y, int dst_w,
			int dst_h, bool smoothing, int clip_x,
			int clip_y, int clip_w, int clip_h);

/* Copy a rectangular area within the D2D back buffer from
   (SRC_X, SRC_Y) to (DST_X, DST_Y) with size WIDTH x HEIGHT.
   Used for scrolling and glyph insertion shifts.  */
extern bool w32_d2d_copy_area_dc (struct w32_output *output,
				  int src_x, int src_y, int width,
				  int height, int dst_x, int dst_y);

/* ----------------------------------------------------------------
   D2D frame lifecycle (begin / end / present)
   ---------------------------------------------------------------- */

/* Begin a D2D drawing frame.  Call at start of redisplay.
   Returns true on success; sets output->d2d_drawing.  */
extern bool w32_d2d_begin_frame (struct w32_output *output);

/* End the current D2D drawing frame.  Call before present.
   Returns true on success.  */
extern bool w32_d2d_end_frame (struct w32_output *output);

/* Present the swap chain to the screen.  If ALLOW_TEARING is true,
   uses DXGI_PRESENT_ALLOW_TEARING for low-latency tearing.
   Returns true on success.  */
extern bool w32_d2d_present (struct w32_output *output,
			     bool allow_tearing);

/* Emacs init entry point for the D3D11/D2D subsystem.  */
extern void syms_of_w32d3d (void);

/* Initialize D3D11/D2D subsystem at runtime (after dump load).
   Called from init sequence in emacs.c; syms_of_w32d3d only
   registers Lisp symbols during the dump process.  */
extern void init_w32d3d (void);

#endif /* HAVE_NTGUI */
#endif /* EMACS_W32D3D_H */
