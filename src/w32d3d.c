/* Direct3D 11 and Direct2D GPU-accelerated rendering for Emacs on
Windows.

This module provides two layers of GPU acceleration:

1. D3D11/DXGI swap chain -- replaces GDI BitBlt for frame
presentation. Drawing still uses GDI through IDXGISurface1::GetDC()
which provides a GPU-backed HDC.  Presenting uses the swap chain
instead of BitBlt.

2. Direct2D DC render target -- provides hardware-accelerated 2D
   drawing (text, rectangles) that can bind to any GDI HDC.  This
   eliminates the double-BitBlt overhead in the DirectWrite text
   rendering path: instead of BitBlt(bg) -> DrawGlyphRun(bitmap) ->
   BitBlt(result), we do BindDC -> DrawGlyphRun -> EndDraw.

Both layers are loaded at runtime so Emacs falls back to GDI when
they are unavailable.  */

#include <config.h>

#ifdef HAVE_NTGUI

/* Needed before dxgi/d3d11/d2d1 headers.  */
# include <windows.h>

/* COBJMACROS gives us C-callable COM vtable macros like
   IDXGISwapChain1_Present, ID2D1DCRenderTarget_DrawGlyphRun, etc.  */
# define COBJMACROS

/* initguid.h MUST come before any COM/DirectX headers so that
   DEFINE_GUID instantiates IIDs rather than declaring them extern. */
# include <initguid.h>

# include <d2d1.h>
# include <d2d1_1.h>
# include <d3d11.h>
# include <dwrite.h>
# include <dxgi.h>
# include <dxgi1_2.h>
# include <dxgi1_5.h>

# include "lisp.h"
# include "frame.h"
# include "w32d3d.h"
# include "w32term.h"

/* Fix broken MinGW d2d1_1.h COBJMACRO for
   ID2D1DeviceContext::DrawGlyphRun. The header incorrectly calls
   lpVtbl->ID2D1DeviceContext_DrawGlyphRun instead of
   lpVtbl->DrawGlyphRun.  */
# undef ID2D1DeviceContext_DrawGlyphRun
# define ID2D1DeviceContext_DrawGlyphRun(This, baselineOrigin,   \
					 glyphRun,               \
					 glyphRunDescription,    \
					 foregroundBrush,        \
					 measuringMode)          \
   (This)->lpVtbl->DrawGlyphRun (This, baselineOrigin, glyphRun, \
				 glyphRunDescription,            \
				 foregroundBrush, measuringMode)

/* Fix other broken MinGW d2d1_1.h COBJMACROs for ID2D1DeviceContext.
   The header incorrectly references lpVtbl->ID2D1DeviceContext_Method
   instead of lpVtbl->Method.  */
# undef ID2D1DeviceContext_BeginDraw
# define ID2D1DeviceContext_BeginDraw(This) \
   (This)->lpVtbl->Base.BeginDraw ((ID2D1RenderTarget *) (This))

# undef ID2D1DeviceContext_EndDraw
# define ID2D1DeviceContext_EndDraw(This, tag1, tag2)                \
   (This)->lpVtbl->Base.EndDraw ((ID2D1RenderTarget *) (This), tag1, \
				 tag2)

# undef ID2D1DeviceContext_CreateSolidColorBrush
# define ID2D1DeviceContext_CreateSolidColorBrush(This, color,    \
						  props, brush)   \
   (This)                                                         \
     ->lpVtbl->Base                                               \
     .CreateSolidColorBrush ((ID2D1RenderTarget *) (This), color, \
			     props, (ID2D1SolidColorBrush **) brush)

# undef ID2D1DeviceContext_FillRectangle
# define ID2D1DeviceContext_FillRectangle(This, rect, brush)         \
   (This)->lpVtbl->Base.FillRectangle ((ID2D1RenderTarget *) (This), \
				       rect, brush)

# undef ID2D1DeviceContext_DrawRectangle
# define ID2D1DeviceContext_DrawRectangle(This, rect, brush,         \
					  strokeWidth, strokeStyle)  \
   (This)->lpVtbl->Base.DrawRectangle ((ID2D1RenderTarget *) (This), \
				       rect, brush, strokeWidth,     \
				       strokeStyle)

# undef ID2D1DeviceContext_DrawLine
# define ID2D1DeviceContext_DrawLine(This, p0, p1, brush,           \
				     strokeWidth, strokeStyle)      \
   (This)->lpVtbl->Base.DrawLine ((ID2D1RenderTarget *) (This), p0, \
				  p1, brush, strokeWidth,           \
				  strokeStyle)

# undef ID2D1DeviceContext_DrawBitmap
# define ID2D1DeviceContext_DrawBitmap(This, bitmap,               \
				       destinationRectangle,       \
				       opacity, interpolationMode, \
				       sourceRectangle,            \
				       perspectiveTransform)       \
   (This)->lpVtbl->DrawBitmap (This, bitmap, destinationRectangle, \
			       opacity, interpolationMode,         \
			       sourceRectangle,                    \
			       perspectiveTransform)

# undef ID2D1DeviceContext_PushAxisAlignedClip
# define ID2D1DeviceContext_PushAxisAlignedClip(This, clipRect, \
						mode)           \
   (This)->lpVtbl->Base.PushAxisAlignedClip ((ID2D1RenderTarget \
						*) (This),      \
					     clipRect, mode)

# undef ID2D1DeviceContext_PopAxisAlignedClip
# define ID2D1DeviceContext_PopAxisAlignedClip(This) \
   (This)->lpVtbl->Base.PopAxisAlignedClip (         \
     (ID2D1RenderTarget *) (This))

# undef ID2D1DeviceContext_GetAntialiasMode
# define ID2D1DeviceContext_GetAntialiasMode(This) \
   (This)->lpVtbl->Base.GetAntialiasMode (         \
     (ID2D1RenderTarget *) (This))

# undef ID2D1DeviceContext_SetAntialiasMode
# define ID2D1DeviceContext_SetAntialiasMode(This, mode)            \
   (This)                                                           \
     ->lpVtbl->Base.SetAntialiasMode ((ID2D1RenderTarget *) (This), \
				      mode)

# undef ID2D1DeviceContext_SetDpi
# define ID2D1DeviceContext_SetDpi(This, dpiX, dpiY)                \
   (This)->lpVtbl->Base.SetDpi ((ID2D1RenderTarget *) (This), dpiX, \
				dpiY)

# undef ID2D1DeviceContext_SetTextAntialiasMode
# define ID2D1DeviceContext_SetTextAntialiasMode(This, mode)     \
   (This)->lpVtbl->Base.SetTextAntialiasMode ((ID2D1RenderTarget \
						 *) (This),      \
					      mode)

# undef ID2D1DeviceContext_Release
# define ID2D1DeviceContext_Release(This) \
   (This)->lpVtbl->Base.Base.Base.Release ((IUnknown *) (This))

# undef ID2D1DeviceContext_SetTarget
# define ID2D1DeviceContext_SetTarget(This, target) \
   (This)->lpVtbl->SetTarget (This, target)

/* Fix broken ID2D1Device macro.  */
# undef ID2D1Device_Release
# define ID2D1Device_Release(This) \
   (This)->lpVtbl->Base.Base.Release ((IUnknown *) (This))

/* Fix broken ID2D1Bitmap1 macro.  */
# undef ID2D1Bitmap1_Release
# define ID2D1Bitmap1_Release(This) \
   (This)->lpVtbl->Base.Base.Base.Base.Release ((IUnknown *) (This))

/* ID2D1Image forward declaration for SetTarget - the MinGW headers
   may not define this type correctly in all cases.  */
typedef struct ID2D1Image ID2D1Image;

/* ================================================================
   D3D11 / DXGI layer
   ================================================================ */

/* ----------------------------------------------------------------
   Runtime-loaded function pointers (D3D11 + DXGI)
   ---------------------------------------------------------------- */

typedef HRESULT (WINAPI *PFN_D3D11_CREATE_DEVICE) (
  IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
  const D3D_FEATURE_LEVEL *, UINT, UINT, ID3D11Device **,
  D3D_FEATURE_LEVEL *, ID3D11DeviceContext **);

typedef HRESULT (WINAPI *PFN_CREATE_DXGI_FACTORY2) (UINT, REFIID,
						    void **);

static PFN_D3D11_CREATE_DEVICE fn_D3D11CreateDevice;
static PFN_CREATE_DXGI_FACTORY2 fn_CreateDXGIFactory2;

/* ----------------------------------------------------------------
   Global D3D11 state (shared across all frames)
   ---------------------------------------------------------------- */

static HMODULE d3d11_dll;
static HMODULE dxgi_dll;
static ID3D11Device *d3d11_device;
static ID3D11DeviceContext *d3d11_context;
static IDXGIFactory2 *dxgi_factory;
static bool d3d_initialized;
static bool d3d_allow_tearing;
static const char
  *d3d_init_error; /* Track initialization failure reason */
static const char
  *d2d_init_error; /* Track D2D initialization failure reason */
static const char *d3d_init_trace
  = "not-called"; /* Step-by-step init trace */
static const char *syms_trace
  = "syms-not-called"; /* Track syms_of_w32d3d progress */
static const char *swap_chain_trace
  = "not-attempted"; /* Last swap-chain creation outcome.  */
static HRESULT swap_chain_hr_flip_discard;
static HRESULT swap_chain_hr_flip_sequential;
static HRESULT swap_chain_hr_gdi_sequential;
static const char *d2d_output_trace
  = "not-attempted"; /* Last D2D output-target creation outcome.  */
static HRESULT d2d_factory1_qi_hr;
static HRESULT d2d_create_device_hr;
static HRESULT d2d_create_context_hr;
static HRESULT d2d_get_surface_hr;
static HRESULT d2d_create_target_hr;

/* Forward declarations for D2D output target functions (used in D3D
   swap chain code before the D2D section defines them).  */
static void w32_d2d_release_output_target (struct w32_output *output);
static bool w32_d2d_create_output_target (struct w32_output *output);

/* ----------------------------------------------------------------
   D3D11 initialization and shutdown
   ---------------------------------------------------------------- */

bool
w32_d3d_available_p (void)
{
  return d3d_initialized && d3d11_device != NULL;
}

bool
w32_d3d_init (void)
{
  HRESULT hr;
  D3D_FEATURE_LEVEL feature_levels[] = {
    D3D_FEATURE_LEVEL_11_1,
    D3D_FEATURE_LEVEL_11_0,
    D3D_FEATURE_LEVEL_10_1,
    D3D_FEATURE_LEVEL_10_0,
  };
  D3D_FEATURE_LEVEL actual_level;

  if (d3d_initialized)
    return d3d11_device != NULL;

  d3d_init_trace = "entered";
  d3d_initialized = true;
  d3d_init_error = NULL;

  /* Load d3d11.dll at runtime.  */
  d3d11_dll = LoadLibrary ("d3d11.dll");
  if (!d3d11_dll)
    {
      d3d_init_error = "LoadLibrary d3d11.dll failed";
      d3d_init_trace = "d3d11-load-failed";
      return false;
    }
  d3d_init_trace = "d3d11-loaded";

  fn_D3D11CreateDevice
    = (PFN_D3D11_CREATE_DEVICE) GetProcAddress (d3d11_dll,
						"D3D11CreateDevice");
  if (!fn_D3D11CreateDevice)
    {
      d3d_init_error = "GetProcAddress D3D11CreateDevice failed";
      FreeLibrary (d3d11_dll);
      d3d11_dll = NULL;
      return false;
    }

  /* Load dxgi.dll at runtime.  */
  dxgi_dll = LoadLibrary ("dxgi.dll");
  if (!dxgi_dll)
    {
      d3d_init_error = "LoadLibrary dxgi.dll failed";
      FreeLibrary (d3d11_dll);
      d3d11_dll = NULL;
      return false;
    }

  fn_CreateDXGIFactory2 = (PFN_CREATE_DXGI_FACTORY2)
    GetProcAddress (dxgi_dll, "CreateDXGIFactory2");
  /* Fall back to CreateDXGIFactory1 if Factory2 is unavailable
     (Windows 7 without platform update).  */
  if (!fn_CreateDXGIFactory2)
    {
      typedef HRESULT (WINAPI * PFN_F1) (REFIID, void **);
      PFN_F1 fn_f1
	= (PFN_F1) GetProcAddress (dxgi_dll, "CreateDXGIFactory1");
      if (!fn_f1)
	{
	  d3d_init_error = "GetProcAddress CreateDXGIFactory1 failed";
	  goto fail_dxgi;
	}

      /* Try directly as IDXGIFactory2.  */
      hr = fn_f1 (&IID_IDXGIFactory2, (void **) &dxgi_factory);
      if (FAILED (hr))
	{
	  /* Create as Factory1 and QI for Factory2.  */
	  IDXGIFactory1 *factory1 = NULL;
	  hr = fn_f1 (&IID_IDXGIFactory1, (void **) &factory1);
	  if (SUCCEEDED (hr) && factory1)
	    {
	      hr = IDXGIFactory1_QueryInterface (factory1,
						 &IID_IDXGIFactory2,
						 (void *
						    *) &dxgi_factory);
	      IDXGIFactory1_Release (factory1);
	    }
	  if (FAILED (hr))
	    {
	      d3d_init_error = "IDXGIFactory2 creation failed";
	      goto fail_dxgi;
	    }
	}
    }
  else
    {
      hr = fn_CreateDXGIFactory2 (0, &IID_IDXGIFactory2,
				  (void **) &dxgi_factory);
      if (FAILED (hr))
	goto fail_dxgi;
    }

  /* Create the D3D11 device with BGRA support (required for
     GDI-compatible surfaces).  */
  hr = fn_D3D11CreateDevice (NULL, /* default adapter */
			     D3D_DRIVER_TYPE_HARDWARE,
			     NULL, /* no software module */
			     D3D11_CREATE_DEVICE_BGRA_SUPPORT,
			     feature_levels,
			     ARRAYELTS (feature_levels),
			     D3D11_SDK_VERSION, &d3d11_device,
			     &actual_level, &d3d11_context);

  if (FAILED (hr))
    {
      /* Try WARP (software) driver as fallback.  */
      hr = fn_D3D11CreateDevice (NULL, D3D_DRIVER_TYPE_WARP, NULL,
				 D3D11_CREATE_DEVICE_BGRA_SUPPORT,
				 feature_levels,
				 ARRAYELTS (feature_levels),
				 D3D11_SDK_VERSION, &d3d11_device,
				 &actual_level, &d3d11_context);
    }

  if (FAILED (hr))
    {
      d3d_init_error
	= "D3D11CreateDevice failed (both hardware and WARP)";
      IDXGIFactory2_Release (dxgi_factory);
      dxgi_factory = NULL;
      goto fail_dxgi;
    }

  /* Check for tearing support (DXGI 1.5+, Windows 10+).  */
  {
    IDXGIFactory5 *factory5 = NULL;
    HRESULT hr5 = IDXGIFactory2_QueryInterface (dxgi_factory,
						&IID_IDXGIFactory5,
						(void **) &factory5);
    if (SUCCEEDED (hr5) && factory5)
      {
	BOOL allow_tearing = FALSE;
	hr5 = IDXGIFactory5_CheckFeatureSupport (
	  factory5, DXGI_FEATURE_PRESENT_ALLOW_TEARING,
	  &allow_tearing, sizeof (allow_tearing));
	if (SUCCEEDED (hr5) && allow_tearing)
	  d3d_allow_tearing = true;
	IDXGIFactory5_Release (factory5);
      }
  }

  return true;

fail_dxgi:
  FreeLibrary (dxgi_dll);
  FreeLibrary (d3d11_dll);
  dxgi_dll = NULL;
  d3d11_dll = NULL;
  return false;
}

void
w32_d3d_shutdown (void)
{
  if (d3d11_context)
    {
      ID3D11DeviceContext_Release (d3d11_context);
      d3d11_context = NULL;
    }
  if (d3d11_device)
    {
      ID3D11Device_Release (d3d11_device);
      d3d11_device = NULL;
    }
  if (dxgi_factory)
    {
      IDXGIFactory2_Release (dxgi_factory);
      dxgi_factory = NULL;
    }
  if (d3d11_dll)
    {
      FreeLibrary (d3d11_dll);
      d3d11_dll = NULL;
    }
  if (dxgi_dll)
    {
      FreeLibrary (dxgi_dll);
      dxgi_dll = NULL;
    }

  w32_d2d_shutdown ();
  d3d_initialized = false;
}

/* ----------------------------------------------------------------
   Per-frame swap chain management
   ---------------------------------------------------------------- */

bool
w32_d3d_create_swap_chain (struct w32_output *output, HWND hwnd,
			   int width, int height)
{
  HRESULT hr;
  IDXGISwapChain1 *swap_chain = NULL;
  DXGI_SWAP_CHAIN_DESC1 desc;

  swap_chain_trace = "entered";
  swap_chain_hr_flip_discard = S_OK;
  swap_chain_hr_flip_sequential = S_OK;
  swap_chain_hr_gdi_sequential = S_OK;

  if (!w32_d3d_available_p ())
    {
      swap_chain_trace = "d3d-unavailable";
      return false;
    }

  /* If a swap chain already exists, release it first.  */
  if (output->dxgi_swap_chain)
    w32_d3d_release_swap_chain (output);

  memset (&desc, 0, sizeof (desc));
  desc.Width = width;
  desc.Height = height;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  desc.Scaling = DXGI_SCALING_NONE;
  desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

  /* Use flip-sequential which preserves the back buffer contents
     between presents.  This is essential because Emacs performs
     incremental redraws — only changed regions are repainted each
     cycle.  Flip-discard would discard the back buffer after every
     present, leaving undefined content in non-repainted areas.  */
  desc.BufferCount = 2;
  desc.Scaling = DXGI_SCALING_NONE;
  desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  desc.Flags = 0;
  hr
    = IDXGIFactory2_CreateSwapChainForHwnd (dxgi_factory,
					    (IUnknown *) d3d11_device,
					    hwnd, &desc, NULL, NULL,
					    &swap_chain);
  swap_chain_hr_flip_sequential = hr;
  if (FAILED (hr) || !swap_chain)
    {
      swap_chain_hr_gdi_sequential = E_NOTIMPL;
      swap_chain_trace = "all-failed";
      return false;
    }

  output->dxgi_swap_chain = swap_chain;
  output->allow_tearing = 0;
  w32_d2d_release_output_target (output);
  w32_d2d_create_output_target (output);
  swap_chain_hr_gdi_sequential = E_NOTIMPL;
  swap_chain_trace = "flip-sequential";
  return true;
}

void
w32_d3d_release_swap_chain (struct w32_output *output)
{
  w32_d2d_release_output_target (output);

  if (output->dxgi_surface)
    {
      IDXGISurface1_Release (output->dxgi_surface);
      output->dxgi_surface = NULL;
    }

  if (output->dxgi_swap_chain)
    {
      IDXGISwapChain1_Release (output->dxgi_swap_chain);
      output->dxgi_swap_chain = NULL;
    }
}

/* ----------------------------------------------------------------
   GDI DC interop -- acquire/release an HDC from the swap chain
   ---------------------------------------------------------------- */

HDC
w32_d3d_acquire_dc (struct w32_output *output)
{
  HRESULT hr;
  IDXGISurface1 *surface = NULL;
  HDC hdc = NULL;

  if (!output->dxgi_swap_chain)
    return NULL;

  /* Get the back buffer surface.  */
  hr = IDXGISwapChain1_GetBuffer (output->dxgi_swap_chain, 0,
				  &IID_IDXGISurface1,
				  (void **) &surface);
  if (FAILED (hr) || !surface)
    return NULL;

  /* Get a GDI-compatible DC from the surface.  The FALSE argument
     means we do NOT discard the existing contents -- we want to
     draw incrementally on top of what is already there.  */
  hr = IDXGISurface1_GetDC (surface, FALSE, &hdc);
  if (FAILED (hr) || !hdc)
    {
      IDXGISurface1_Release (surface);
      return NULL;
    }

  output->dxgi_surface = surface;
  return hdc;
}

void
w32_d3d_release_dc (struct w32_output *output)
{
  if (output->dxgi_surface)
    {
      IDXGISurface1_ReleaseDC (output->dxgi_surface, NULL);

      IDXGISurface1_Release (output->dxgi_surface);
      output->dxgi_surface = NULL;
    }
}

/* ----------------------------------------------------------------
   Present
   ---------------------------------------------------------------- */

void
w32_d3d_present (struct w32_output *output)
{
  HRESULT hr;
  UINT sync_interval = 1;
  UINT flags = 0;

  if (!output->dxgi_swap_chain)
    return;

  /* Use tearing if the swap chain supports it.  */
  if (output->allow_tearing)
    {
      sync_interval = 0;
      flags = DXGI_PRESENT_ALLOW_TEARING;
    }

  hr = IDXGISwapChain1_Present (output->dxgi_swap_chain,
				sync_interval, flags);

  /* If the device was removed (GPU reset, driver update, etc.),
     mark D3D as unavailable so the frame falls back to GDI.  */
  if (hr == DXGI_ERROR_DEVICE_REMOVED
      || hr == DXGI_ERROR_DEVICE_RESET)
    {
      w32_d3d_release_swap_chain (output);
      output->use_d3d = 0;
    }
}

/* ----------------------------------------------------------------
   Resize
   ---------------------------------------------------------------- */

bool
w32_d3d_resize (struct w32_output *output, int width, int height)
{
  HRESULT hr;
  UINT flags;

  if (!output->dxgi_swap_chain)
    return false;

  w32_d2d_release_output_target (output);

  /* Must release all references to the back buffer before
     resizing.  */
  if (output->dxgi_surface)
    {
      IDXGISurface1_Release (output->dxgi_surface);
      output->dxgi_surface = NULL;
    }

  /* Preserve the swap chain flags used at creation.  */
  flags
    = output->allow_tearing ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0;

  hr = IDXGISwapChain1_ResizeBuffers (output->dxgi_swap_chain, 0,
				      width, height,
				      DXGI_FORMAT_UNKNOWN, flags);
  if (FAILED (hr))
    {
      /* Resize failed -- release swap chain, caller will fall back
	 to GDI.  */
      w32_d3d_release_swap_chain (output);
      return false;
    }

  w32_d2d_create_output_target (output);
  return true;
}

void
w32_d3d_disable (struct w32_output *output)
{
  output->d3d_direct_dc = 0;
  output->use_d3d = 0;
  output->paint_buffer = NULL;
  w32_d2d_release_output_target (output);
  w32_d3d_release_swap_chain (output);
}

/* ================================================================
   Direct2D DC render target layer
   ================================================================

   ID2D1DCRenderTarget binds to any GDI HDC for drawing.  This lets
   us draw glyphs and fill rectangles with D2D hardware acceleration
   on the existing GDI memory bitmap (paint_dc), without changing
   the overall architecture.

   The key benefit: DirectWrite's w32_dwrite_draw currently does
     BitBlt(bg) -> DrawGlyphRun(bitmap) -> BitBlt(result)
   With D2D, this becomes:
     BindDC(hdc) -> BeginDraw -> DrawGlyphRun -> EndDraw
   Eliminating both BitBlt operations entirely.  */

/* ----------------------------------------------------------------
   Runtime-loaded function pointer (D2D1)
   ---------------------------------------------------------------- */

typedef HRESULT (WINAPI *PFN_D2D1_CREATE_FACTORY) (
  D2D1_FACTORY_TYPE, REFIID, const D2D1_FACTORY_OPTIONS *, void **);

static PFN_D2D1_CREATE_FACTORY fn_D2D1CreateFactory;

/* ----------------------------------------------------------------
   Global D2D state
   ---------------------------------------------------------------- */

static HMODULE d2d1_dll;
static ID2D1Factory *d2d1_factory;
static ID2D1Factory1 *d2d1_factory1;
static ID2D1Device *d2d1_device;
static ID2D1DCRenderTarget *d2d_dc_target;
static bool d2d_initialized;

static void w32_d2d_release_output_target (struct w32_output *output);
static bool w32_d2d_create_output_target (struct w32_output *output);

/* ----------------------------------------------------------------
   D2D initialization
   ---------------------------------------------------------------- */

bool
w32_d2d_available_p (void)
{
  return d2d_initialized && d2d_dc_target != NULL;
}

static bool
w32_d2d_init (void)
{
  HRESULT hr;
  D2D1_RENDER_TARGET_PROPERTIES rt_props;
  ID2D1Factory1 *factory1 = NULL;

  if (d2d_initialized)
    return d2d_dc_target != NULL;

  d2d_initialized = true;

  /* Load d2d1.dll at runtime.  */
  d2d1_dll = LoadLibrary ("d2d1.dll");
  if (!d2d1_dll)
    return false;

  fn_D2D1CreateFactory
    = (PFN_D2D1_CREATE_FACTORY) GetProcAddress (d2d1_dll,
						"D2D1CreateFactory");
  if (!fn_D2D1CreateFactory)
    {
      FreeLibrary (d2d1_dll);
      d2d1_dll = NULL;
      return false;
    }

  /* Create D2D factory.  Single-threaded because Emacs draws
     exclusively from the main (Lisp) thread.  Prefer ID2D1Factory1
     for D2D device/context creation, but fall back to ID2D1Factory.
   */
  hr
    = fn_D2D1CreateFactory (D2D1_FACTORY_TYPE_SINGLE_THREADED,
			    &IID_ID2D1Factory1, NULL, /* no options */
			    (void **) &factory1);
  if (SUCCEEDED (hr) && factory1)
    {
      d2d1_factory1 = factory1;
      d2d1_factory = (ID2D1Factory *) factory1;
      d2d_factory1_qi_hr = S_OK;
    }
  else
    {
      hr = fn_D2D1CreateFactory (D2D1_FACTORY_TYPE_SINGLE_THREADED,
				 &IID_ID2D1Factory,
				 NULL, /* no options */
				 (void **) &d2d1_factory);
      if (FAILED (hr) || !d2d1_factory)
	{
	  FreeLibrary (d2d1_dll);
	  d2d1_dll = NULL;
	  return false;
	}

      /* Try to upgrade base factory to ID2D1Factory1 when available.
	 This is needed for per-frame device-context rendering.  */
      d2d_factory1_qi_hr
	= ID2D1Factory_QueryInterface (d2d1_factory,
				       &IID_ID2D1Factory1,
				       (void **) &d2d1_factory1);
    }

  if (!d2d1_factory)
    {
      FreeLibrary (d2d1_dll);
      d2d1_dll = NULL;
      return false;
    }

  /* Create a DC render target.  This is a singleton that can be
     re-bound to different HDCs via BindDC().

     D2D1_RENDER_TARGET_TYPE_DEFAULT lets D2D choose hardware
     vs software.  GDI_COMPATIBLE usage allows mixed D2D/GDI
     drawing on the same surface (needed for operations not yet
     ported to D2D).  */
  memset (&rt_props, 0, sizeof (rt_props));
  rt_props.type = D2D1_RENDER_TARGET_TYPE_DEFAULT;
  rt_props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
  rt_props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
  rt_props.dpiX = 0; /* Use default DPI.  */
  rt_props.dpiY = 0;
  rt_props.usage = D2D1_RENDER_TARGET_USAGE_GDI_COMPATIBLE;
  rt_props.minLevel = D2D1_FEATURE_LEVEL_DEFAULT;

  hr = ID2D1Factory_CreateDCRenderTarget (d2d1_factory, &rt_props,
					  &d2d_dc_target);
  if (FAILED (hr) || !d2d_dc_target)
    {
      ID2D1Factory_Release (d2d1_factory);
      d2d1_factory = NULL;
      FreeLibrary (d2d1_dll);
      d2d1_dll = NULL;
      return false;
    }

  /* Set text antialias mode to match DirectWrite quality.  */
  ID2D1RenderTarget_SetTextAntialiasMode (
    (ID2D1RenderTarget *) d2d_dc_target,
    D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);

  return true;
}

static bool
w32_d2d_init_device (void)
{
  HRESULT hr;
  IDXGIDevice *dxgi_device = NULL;

  if (d2d1_device)
    return true;
  if (!d2d1_factory1 || !d3d11_device)
    {
      d2d_output_trace
	= !d2d1_factory1 ? "no-factory1" : "no-d3d-device";
      return false;
    }

  hr = ID3D11Device_QueryInterface (d3d11_device, &IID_IDXGIDevice,
				    (void **) &dxgi_device);
  if (FAILED (hr) || !dxgi_device)
    {
      d2d_create_device_hr = hr;
      d2d_output_trace = "query-idxgi-device-failed";
      return false;
    }

  hr = ID2D1Factory1_CreateDevice (d2d1_factory1, dxgi_device,
				   &d2d1_device);
  IDXGIDevice_Release (dxgi_device);
  if (FAILED (hr) || !d2d1_device)
    {
      d2d_create_device_hr = hr;
      d2d_output_trace = "create-d2d-device-failed";
      return false;
    }

  d2d_create_device_hr = hr;

  return true;
}

void
w32_d2d_shutdown (void)
{
  if (d2d_dc_target)
    {
      ID2D1DCRenderTarget_Release (d2d_dc_target);
      d2d_dc_target = NULL;
    }
  if (d2d1_device)
    {
      ID2D1Device_Release (d2d1_device);
      d2d1_device = NULL;
    }
  if (d2d1_factory1)
    {
      ID2D1Factory1_Release (d2d1_factory1);
      d2d1_factory1 = NULL;
      d2d1_factory = NULL;
    }
  else if (d2d1_factory)
    {
      ID2D1Factory_Release (d2d1_factory);
      d2d1_factory = NULL;
    }
  if (d2d1_dll)
    {
      FreeLibrary (d2d1_dll);
      d2d1_dll = NULL;
    }
  d2d_initialized = false;
}

static void
w32_d2d_release_output_target (struct w32_output *output)
{
  if (!output)
    return;

  if (output->d2d_cached_brush)
    {
      ID2D1SolidColorBrush_Release (output->d2d_cached_brush);
      output->d2d_cached_brush = NULL;
    }
  output->d2d_cached_brush_valid = 0;
  output->d2d_cached_brush_color = 0;

  if (output->d2d_cached_bitmap)
    {
      ID2D1Bitmap_Release (output->d2d_cached_bitmap);
      output->d2d_cached_bitmap = NULL;
    }
  output->d2d_cached_pixmap = NULL;
  output->d2d_cached_mask = NULL;
  output->d2d_cached_width = 0;
  output->d2d_cached_height = 0;

  if (output->d2d_context)
    ID2D1DeviceContext_SetTarget (output->d2d_context, NULL);

  if (output->d2d_target)
    {
      ID2D1Bitmap1_Release (output->d2d_target);
      output->d2d_target = NULL;
    }

  if (output->d2d_context)
    {
      ID2D1DeviceContext_Release (output->d2d_context);
      output->d2d_context = NULL;
    }
}

static bool
w32_d2d_create_output_target (struct w32_output *output)
{
  HRESULT hr;
  IDXGISurface *surface = NULL;
  D2D1_BITMAP_PROPERTIES1 props;

  d2d_output_trace = "entered";
  d2d_create_context_hr = S_OK;
  d2d_get_surface_hr = S_OK;
  d2d_create_target_hr = S_OK;

  if (!output || !output->dxgi_swap_chain)
    {
      d2d_output_trace = "no-swap-chain";
      return false;
    }
  if (!w32_d2d_init_device ())
    return false;

  if (!output->d2d_context)
    {
      hr = ID2D1Device_CreateDeviceContext (
	d2d1_device, D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
	&output->d2d_context);
      if (FAILED (hr) || !output->d2d_context)
	{
	  d2d_create_context_hr = hr;
	  d2d_output_trace = "create-device-context-failed";
	  return false;
	}

      d2d_create_context_hr = hr;

      ID2D1DeviceContext_SetDpi (output->d2d_context, 96.0f, 96.0f);
      ID2D1DeviceContext_SetTextAntialiasMode (
	output->d2d_context, D2D1_TEXT_ANTIALIAS_MODE_CLEARTYPE);
    }

  hr = IDXGISwapChain1_GetBuffer (output->dxgi_swap_chain, 0,
				  &IID_IDXGISurface,
				  (void **) &surface);
  if (FAILED (hr) || !surface)
    {
      d2d_get_surface_hr = hr;
      d2d_output_trace = "swapchain-get-buffer-failed";
      return false;
    }

  d2d_get_surface_hr = hr;

  memset (&props, 0, sizeof (props));
  props.dpiX = 96.0f;
  props.dpiY = 96.0f;

  /* Some drivers are strict about swap-chain target bitmap options.
     Try modern target settings first, then progressively relax.  */
  props.pixelFormat.format = DXGI_FORMAT_UNKNOWN;
  props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
  props.bitmapOptions
    = (D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW);
  hr = ID2D1DeviceContext_CreateBitmapFromDxgiSurface (
    output->d2d_context, surface, &props, &output->d2d_target);
  if (FAILED (hr) || !output->d2d_target)
    {
      props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
      props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
      props.bitmapOptions = (D2D1_BITMAP_OPTIONS_TARGET
			     | D2D1_BITMAP_OPTIONS_CANNOT_DRAW);
      hr = ID2D1DeviceContext_CreateBitmapFromDxgiSurface (
	output->d2d_context, surface, &props, &output->d2d_target);
      if (FAILED (hr) || !output->d2d_target)
	{
	  props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
	  props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
	  props.bitmapOptions = (D2D1_BITMAP_OPTIONS_TARGET
				 | D2D1_BITMAP_OPTIONS_CANNOT_DRAW);
	  hr = ID2D1DeviceContext_CreateBitmapFromDxgiSurface (
	    output->d2d_context, surface, &props,
	    &output->d2d_target);
	  if (FAILED (hr) || !output->d2d_target)
	    {
	      props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
	      props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
	      props.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET;
	      hr = ID2D1DeviceContext_CreateBitmapFromDxgiSurface (
		output->d2d_context, surface, &props,
		&output->d2d_target);
	    }
	}
    }
  IDXGISurface_Release (surface);
  if (FAILED (hr) || !output->d2d_target)
    {
      d2d_create_target_hr = hr;
      d2d_output_trace = "create-target-bitmap-failed";
      w32_d2d_release_output_target (output);
      return false;
    }

  d2d_create_target_hr = hr;

  ID2D1DeviceContext_SetTarget (output->d2d_context,
				(ID2D1Image *) output->d2d_target);

  d2d_output_trace = "created";

  return true;
}

/* ----------------------------------------------------------------
   D2D drawing operations
   ---------------------------------------------------------------- */

/* Helper: convert COLORREF (0x00BBGGRR) to D2D1_COLOR_F.  */
static D2D1_COLOR_F
colorref_to_d2d (COLORREF c)
{
  D2D1_COLOR_F color;
  color.r = (float) GetRValue (c) / 255.0f;
  color.g = (float) GetGValue (c) / 255.0f;
  color.b = (float) GetBValue (c) / 255.0f;
  color.a = 1.0f;
  return color;
}

static ID2D1SolidColorBrush *
w32_d2d_get_cached_brush (struct w32_output *output, COLORREF color)
{
  HRESULT hr;
  D2D1_COLOR_F d2d_color;

  if (!output || !output->d2d_context)
    return NULL;

  if (output->d2d_cached_brush_valid && output->d2d_cached_brush
      && output->d2d_cached_brush_color == color)
    return output->d2d_cached_brush;

  if (output->d2d_cached_brush)
    {
      ID2D1SolidColorBrush_Release (output->d2d_cached_brush);
      output->d2d_cached_brush = NULL;
      output->d2d_cached_brush_valid = 0;
    }

  d2d_color = colorref_to_d2d (color);
  hr = ID2D1DeviceContext_CreateSolidColorBrush (
    output->d2d_context, &d2d_color, NULL, &output->d2d_cached_brush);
  if (FAILED (hr) || !output->d2d_cached_brush)
    return NULL;

  output->d2d_cached_brush_color = color;
  output->d2d_cached_brush_valid = 1;
  return output->d2d_cached_brush;
}

/* Begin a D2D drawing session: bind the render target to HDC,
   call BeginDraw, and create a solid color brush.  Returns the
   brush on success, NULL on failure (EndDraw is called on error
   so the caller need not clean up).  */
static ID2D1SolidColorBrush *
d2d_begin_draw (HDC hdc, RECT *bind_rect, COLORREF color)
{
  HRESULT hr;
  ID2D1SolidColorBrush *brush = NULL;
  D2D1_COLOR_F d2d_color;

  hr = ID2D1DCRenderTarget_BindDC (d2d_dc_target, hdc, bind_rect);
  if (FAILED (hr))
    return NULL;

  ID2D1RenderTarget_BeginDraw ((ID2D1RenderTarget *) d2d_dc_target);

  d2d_color = colorref_to_d2d (color);
  hr = ID2D1RenderTarget_CreateSolidColorBrush ((ID2D1RenderTarget *)
						  d2d_dc_target,
						&d2d_color, NULL,
						&brush);
  if (FAILED (hr) || !brush)
    {
      ID2D1RenderTarget_EndDraw ((ID2D1RenderTarget *) d2d_dc_target,
				 NULL, NULL);
      return NULL;
    }

  return brush;
}

/* End a D2D drawing session: release the brush and call EndDraw.
   Returns true if EndDraw succeeded.  */
static bool
d2d_end_draw (ID2D1SolidColorBrush *brush)
{
  HRESULT hr;

  ID2D1SolidColorBrush_Release (brush);
  hr = ID2D1RenderTarget_EndDraw ((ID2D1RenderTarget *) d2d_dc_target,
				  NULL, NULL);
  return SUCCEEDED (hr);
}

bool
w32_d2d_draw_glyphs (HDC hdc, int x, int y, void *font_face,
		     float font_size, const unsigned short *indices,
		     const float *advances, int len, COLORREF color,
		     int area_x, int area_y, int area_w, int area_h)
{
  RECT bind_rect;
  ID2D1SolidColorBrush *brush;
  D2D1_POINT_2F baseline_origin;
  DWRITE_GLYPH_RUN glyph_run;

  if (!w32_d2d_available_p () || !font_face || len <= 0)
    return false;

  bind_rect.left = area_x;
  bind_rect.top = area_y;
  bind_rect.right = area_x + area_w;
  bind_rect.bottom = area_y + area_h;

  brush = d2d_begin_draw (hdc, &bind_rect, color);
  if (!brush)
    return false;

  /* Build the DWRITE_GLYPH_RUN structure.  */
  memset (&glyph_run, 0, sizeof (glyph_run));
  glyph_run.fontFace = (IDWriteFontFace *) font_face;
  glyph_run.fontEmSize = font_size;
  glyph_run.glyphCount = len;
  glyph_run.glyphIndices = indices;
  glyph_run.glyphAdvances = advances;

  /* The baseline origin is relative to the bind rect.
     x,y are in absolute coordinates; shift to bind-rect-relative.  */
  baseline_origin.x = (float) (x - area_x);
  baseline_origin.y = (float) (y - area_y);

  ID2D1RenderTarget_DrawGlyphRun ((ID2D1RenderTarget *) d2d_dc_target,
				  baseline_origin, &glyph_run,
				  (ID2D1Brush *) brush,
				  DWRITE_MEASURING_MODE_GDI_CLASSIC);

  return d2d_end_draw (brush);
}

bool
w32_d2d_fill_rect (HDC hdc, int x, int y, int w, int h,
		   COLORREF color)
{
  RECT bind_rect;
  ID2D1SolidColorBrush *brush;
  D2D1_RECT_F fill_rect;

  if (!w32_d2d_available_p ())
    return false;

  bind_rect.left = x;
  bind_rect.top = y;
  bind_rect.right = x + w;
  bind_rect.bottom = y + h;

  brush = d2d_begin_draw (hdc, &bind_rect, color);
  if (!brush)
    return false;

  /* Fill rect is relative to the bind rect origin.  */
  fill_rect.left = 0.0f;
  fill_rect.top = 0.0f;
  fill_rect.right = (float) w;
  fill_rect.bottom = (float) h;

  ID2D1RenderTarget_FillRectangle ((ID2D1RenderTarget *)
				     d2d_dc_target,
				   &fill_rect, (ID2D1Brush *) brush);

  return d2d_end_draw (brush);
}

static bool
w32_d2d_bitmap_from_hbitmap (struct w32_output *output,
			     HBITMAP pixmap, HBITMAP mask,
			     ID2D1Bitmap **out_bitmap)
{
  BITMAP bm;
  BITMAPINFO bmi;
  BYTE *pixels = NULL;
  BYTE *mask_pixels = NULL;
  HDC hdc = NULL;
  HRESULT hr;
  D2D1_SIZE_U size;
  D2D1_BITMAP_PROPERTIES props;
  int y;
  bool mask_applied = false;

  *out_bitmap = NULL;

  if (!output || !output->d2d_context || !pixmap)
    return false;

  if (!GetObject (pixmap, sizeof (bm), &bm))
    return false;
  if (bm.bmWidth <= 0 || bm.bmHeight <= 0)
    return false;

  memset (&bmi, 0, sizeof (bmi));
  bmi.bmiHeader.biSize = sizeof (BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = bm.bmWidth;
  bmi.bmiHeader.biHeight = -bm.bmHeight; /* top-down */
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  pixels = xmalloc ((size_t) bm.bmWidth * bm.bmHeight * 4);
  if (!pixels)
    return false;

  hdc = GetDC (NULL);
  if (!hdc)
    goto fail;

  if (!GetDIBits (hdc, pixmap, 0, bm.bmHeight, pixels, &bmi,
		  DIB_RGB_COLORS))
    goto fail;

  if (mask)
    {
      BITMAP mask_bm;

      if (GetObject (mask, sizeof (mask_bm), &mask_bm)
	  && mask_bm.bmWidth == bm.bmWidth
	  && mask_bm.bmHeight == bm.bmHeight)
	{
	  int x;

	  mask_pixels
	    = xmalloc ((size_t) bm.bmWidth * bm.bmHeight * 4);
	  if (!mask_pixels)
	    goto fail;

	  if (!GetDIBits (hdc, mask, 0, bm.bmHeight, mask_pixels,
			  &bmi, DIB_RGB_COLORS))
	    goto fail;

	  /* W32 masks use 0 bits for opaque pixels and non-zero for
	     transparent.  Convert to alpha channel.  */
	  for (y = 0; y < bm.bmHeight; ++y)
	    for (x = 0; x < bm.bmWidth; ++x)
	      {
		BYTE *p = pixels + ((size_t) y * bm.bmWidth + x) * 4;
		BYTE *m
		  = mask_pixels + ((size_t) y * bm.bmWidth + x) * 4;
		/* Monochrome mask polarity for W32 image masks is
		   such that zero means transparent and non-zero means
		   opaque when read back through GetDIBits in this
		   conversion path.  */
		bool transparent = (m[0] | m[1] | m[2]) == 0;

		if (transparent)
		  {
		    p[0] = p[1] = p[2] = 0;
		    p[3] = 0;
		  }
		else
		  p[3] = 255;
	      }

	  mask_applied = true;
	}
    }

  if (!mask_applied)
    {
      /* Source has no usable mask; keep it fully opaque for
	 deterministic toolbar/button rendering.  */
      for (y = 0; y < bm.bmHeight; ++y)
	{
	  int x;
	  for (x = 0; x < bm.bmWidth; ++x)
	    {
	      BYTE *p = pixels + ((size_t) y * bm.bmWidth + x) * 4;
	      p[3] = 255;
	    }
	}
    }

  /* D2D bitmap is PREMULTIPLIED alpha, convert channels now.  */
  for (y = 0; y < bm.bmHeight; ++y)
    {
      int x;
      for (x = 0; x < bm.bmWidth; ++x)
	{
	  BYTE *p = pixels + ((size_t) y * bm.bmWidth + x) * 4;
	  BYTE a = p[3];

	  if (a == 0)
	    p[0] = p[1] = p[2] = 0;
	  else if (a < 255)
	    {
	      p[0] = (BYTE) ((p[0] * a + 127) / 255);
	      p[1] = (BYTE) ((p[1] * a + 127) / 255);
	      p[2] = (BYTE) ((p[2] * a + 127) / 255);
	    }
	}
    }

  size.width = bm.bmWidth;
  size.height = bm.bmHeight;
  props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
  props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED;
  props.dpiX = 96.0f;
  props.dpiY = 96.0f;

  hr = ID2D1RenderTarget_CreateBitmap ((ID2D1RenderTarget *)
					 output->d2d_context,
				       size, pixels, bm.bmWidth * 4,
				       &props, out_bitmap);

  if (FAILED (hr) || !*out_bitmap)
    goto fail;

  if (mask_pixels)
    xfree (mask_pixels);
  xfree (pixels);
  if (hdc)
    ReleaseDC (NULL, hdc);
  return true;

fail:
  if (mask_pixels)
    xfree (mask_pixels);
  if (pixels)
    xfree (pixels);
  if (hdc)
    ReleaseDC (NULL, hdc);
  return false;
}

bool
w32_d2d_draw_bitmap_dc (struct w32_output *output, HBITMAP pixmap,
			HBITMAP mask, int src_x, int src_y, int src_w,
			int src_h, int dst_x, int dst_y, int dst_w,
			int dst_h, bool smoothing, int clip_x,
			int clip_y, int clip_w, int clip_h)
{
  ID2D1Bitmap *bitmap = NULL;
  ID2D1Bitmap *new_bitmap = NULL;
  BITMAP bm;
  bool began_draw = false;
  bool has_clip = false;
  HRESULT hr = S_OK;
  D2D1_RECT_F src_rect;
  D2D1_RECT_F dst_rect;
  D2D1_RECT_F clip_rect;

  if (!output || !output->d2d_context || !output->d2d_target
      || !pixmap)
    return false;

  if (src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0)
    return true;

  if (!GetObject (pixmap, sizeof (bm), &bm) || bm.bmWidth <= 0
      || bm.bmHeight <= 0)
    return false;

  if (output->d2d_cached_bitmap && output->d2d_cached_pixmap == pixmap
      && output->d2d_cached_mask == mask
      && output->d2d_cached_width == bm.bmWidth
      && output->d2d_cached_height == bm.bmHeight)
    bitmap = output->d2d_cached_bitmap;
  else
    {
      if (!w32_d2d_bitmap_from_hbitmap (output, pixmap, mask,
					&new_bitmap))
	return false;

      if (output->d2d_cached_bitmap)
	ID2D1Bitmap_Release (output->d2d_cached_bitmap);

      output->d2d_cached_bitmap = new_bitmap;
      output->d2d_cached_pixmap = pixmap;
      output->d2d_cached_mask = mask;
      output->d2d_cached_width = bm.bmWidth;
      output->d2d_cached_height = bm.bmHeight;
      bitmap = new_bitmap;
    }

  src_rect.left = (FLOAT) src_x;
  src_rect.top = (FLOAT) src_y;
  src_rect.right = (FLOAT) (src_x + src_w);
  src_rect.bottom = (FLOAT) (src_y + src_h);

  dst_rect.left = (FLOAT) dst_x;
  dst_rect.top = (FLOAT) dst_y;
  dst_rect.right = (FLOAT) (dst_x + dst_w);
  dst_rect.bottom = (FLOAT) (dst_y + dst_h);

  if (!output->d2d_drawing)
    {
      ID2D1DeviceContext_BeginDraw (output->d2d_context);
      began_draw = true;
    }

  if (clip_w > 0 && clip_h > 0)
    {
      clip_rect.left = (FLOAT) clip_x;
      clip_rect.top = (FLOAT) clip_y;
      clip_rect.right = (FLOAT) (clip_x + clip_w);
      clip_rect.bottom = (FLOAT) (clip_y + clip_h);
      ID2D1DeviceContext_PushAxisAlignedClip (
	output->d2d_context, &clip_rect, D2D1_ANTIALIAS_MODE_ALIASED);
      has_clip = true;
    }

  ID2D1DeviceContext_DrawBitmap (
    output->d2d_context, bitmap, &dst_rect, 1.0f,
    (D2D1_INTERPOLATION_MODE) ((smoothing && !mask)
				 ? D2D1_BITMAP_INTERPOLATION_MODE_LINEAR
				 : D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR),
    &src_rect, NULL);

  if (has_clip)
    ID2D1DeviceContext_PopAxisAlignedClip (output->d2d_context);

  if (began_draw)
    hr = ID2D1DeviceContext_EndDraw (output->d2d_context, NULL, NULL);

  return SUCCEEDED (hr);
}

/* Copy a rectangular area within the D2D back buffer.  Used for
   scrolling and glyph insertion shifts.  Creates a temporary bitmap
   from the render target, then draws it at the destination.  */
bool
w32_d2d_copy_area_dc (struct w32_output *output, int src_x, int src_y,
		      int width, int height, int dst_x, int dst_y)
{
  ID2D1Bitmap *tmp_bitmap = NULL;
  HRESULT hr;
  D2D1_POINT_2U dest_point;
  D2D1_RECT_U src_rect_u;
  D2D1_SIZE_U bmp_size;
  D2D1_BITMAP_PROPERTIES bmp_props;
  D2D1_RECT_F dst_rect_f;
  D2D1_RECT_F src_rect_f;

  if (!output || !output->d2d_context || !output->d2d_target)
    return false;

  if (width <= 0 || height <= 0)
    return true;

  /* If we're in the middle of a D2D draw session, we need to end it
     before we can read back from the render target.  */
  if (output->d2d_drawing)
    {
      hr = ID2D1DeviceContext_EndDraw (output->d2d_context, NULL,
				       NULL);
      output->d2d_drawing = 0;
      if (FAILED (hr))
	return false;
    }

  /* Create a temporary bitmap compatible with the render target.  */
  bmp_size.width = width;
  bmp_size.height = height;
  bmp_props.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
  bmp_props.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
  bmp_props.dpiX = 96.0f;
  bmp_props.dpiY = 96.0f;

  hr = ID2D1RenderTarget_CreateBitmap ((ID2D1RenderTarget *)
					 output->d2d_context,
				       bmp_size, NULL, 0, &bmp_props,
				       &tmp_bitmap);
  if (FAILED (hr) || !tmp_bitmap)
    {
      w32_d2d_begin_frame (output);
      return false;
    }

  /* Copy from the render target into the temporary bitmap.  */
  dest_point.x = 0;
  dest_point.y = 0;
  src_rect_u.left = src_x;
  src_rect_u.top = src_y;
  src_rect_u.right = src_x + width;
  src_rect_u.bottom = src_y + height;

  hr = ID2D1Bitmap_CopyFromRenderTarget (tmp_bitmap, &dest_point,
					 (ID2D1RenderTarget *)
					   output->d2d_context,
					 &src_rect_u);
  if (FAILED (hr))
    {
      ID2D1Bitmap_Release (tmp_bitmap);
      w32_d2d_begin_frame (output);
      return false;
    }

  /* Begin a new D2D session and draw the bitmap at the destination.
   */
  ID2D1DeviceContext_BeginDraw (output->d2d_context);
  output->d2d_drawing = 1;

  dst_rect_f.left = (FLOAT) dst_x;
  dst_rect_f.top = (FLOAT) dst_y;
  dst_rect_f.right = (FLOAT) (dst_x + width);
  dst_rect_f.bottom = (FLOAT) (dst_y + height);

  src_rect_f.left = 0.0f;
  src_rect_f.top = 0.0f;
  src_rect_f.right = (FLOAT) width;
  src_rect_f.bottom = (FLOAT) height;

  ID2D1DeviceContext_DrawBitmap (
    output->d2d_context, (ID2D1Bitmap *) tmp_bitmap, &dst_rect_f,
    1.0f,
    (D2D1_INTERPOLATION_MODE)
      D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR,
    &src_rect_f, NULL);

  ID2D1Bitmap_Release (tmp_bitmap);

  return true;
}

bool
w32_d2d_draw_glyphs_dc (struct w32_output *output, int x, int y,
			void *font_face, float font_size,
			const unsigned short *indices,
			const float *advances, int len,
			COLORREF color, int area_x, int area_y,
			int area_w, int area_h)
{
  HRESULT hr;
  bool began_draw = false;
  ID2D1SolidColorBrush *brush = NULL;
  DWRITE_GLYPH_RUN glyph_run;
  D2D1_POINT_2F origin;
  D2D1_RECT_F clip_rect;

  if (!output || !output->d2d_context || !output->d2d_target
      || !font_face || len <= 0)
    return false;

  /* Empty clip is a no-op, not a rendering failure.  */
  if (area_w <= 0 || area_h <= 0)
    return true;

  brush = w32_d2d_get_cached_brush (output, color);
  if (!brush)
    return false;

  memset (&glyph_run, 0, sizeof (glyph_run));
  glyph_run.fontFace = (IDWriteFontFace *) font_face;
  glyph_run.fontEmSize = font_size;
  glyph_run.glyphIndices = indices;
  glyph_run.glyphCount = len;
  glyph_run.isSideways = FALSE;
  glyph_run.bidiLevel = 0;
  glyph_run.glyphOffsets = NULL;
  glyph_run.glyphAdvances = advances;

  origin.x = (FLOAT) x;
  origin.y = (FLOAT) y;

  clip_rect.left = (FLOAT) area_x;
  clip_rect.top = (FLOAT) area_y;
  clip_rect.right = (FLOAT) (area_x + area_w);
  clip_rect.bottom = (FLOAT) (area_y + area_h);

  if (!output->d2d_drawing)
    {
      ID2D1DeviceContext_BeginDraw (output->d2d_context);
      began_draw = true;
    }
  ID2D1DeviceContext_PushAxisAlignedClip (
    output->d2d_context, &clip_rect, D2D1_ANTIALIAS_MODE_ALIASED);
  ID2D1DeviceContext_DrawGlyphRun (output->d2d_context, origin,
				   &glyph_run, NULL,
				   (ID2D1Brush *) brush,
				   DWRITE_MEASURING_MODE_GDI_CLASSIC);
  ID2D1DeviceContext_PopAxisAlignedClip (output->d2d_context);
  hr = S_OK;
  if (began_draw)
    hr = ID2D1DeviceContext_EndDraw (output->d2d_context, NULL, NULL);

  return SUCCEEDED (hr);
}

bool
w32_d2d_fill_rect_dc (struct w32_output *output, int x, int y, int w,
		      int h, COLORREF color)
{
  HRESULT hr;
  bool began_draw = false;
  ID2D1SolidColorBrush *brush = NULL;
  D2D1_RECT_F rect;

  if (!output || !output->d2d_context || !output->d2d_target)
    return false;

  if (w <= 0 || h <= 0)
    return true;

  brush = w32_d2d_get_cached_brush (output, color);
  if (!brush)
    return false;

  rect.left = (FLOAT) x;
  rect.top = (FLOAT) y;
  rect.right = (FLOAT) (x + w);
  rect.bottom = (FLOAT) (y + h);

  if (!output->d2d_drawing)
    {
      ID2D1DeviceContext_BeginDraw (output->d2d_context);
      began_draw = true;
    }
  ID2D1DeviceContext_FillRectangle (output->d2d_context, &rect,
				    (ID2D1Brush *) brush);
  hr = S_OK;
  if (began_draw)
    hr = ID2D1DeviceContext_EndDraw (output->d2d_context, NULL, NULL);

  return SUCCEEDED (hr);
}

bool
w32_d2d_draw_rect_dc (struct w32_output *output, int x, int y, int w,
		      int h, COLORREF foreground, COLORREF background)
{
  HRESULT hr;
  bool began_draw = false;
  bool ok = true;
  ID2D1SolidColorBrush *stroke_brush = NULL;
  ID2D1SolidColorBrush *fill_brush = NULL;
  D2D1_COLOR_F stroke_color;
  D2D1_COLOR_F fill_color;
  D2D1_RECT_F rect;
  D2D1_ANTIALIAS_MODE old_mode;

  if (!output || !output->d2d_context || !output->d2d_target)
    return false;

  if (w <= 0 || h <= 0)
    return true;

  stroke_color = colorref_to_d2d (foreground);
  fill_color = colorref_to_d2d (background);

  hr = ID2D1DeviceContext_CreateSolidColorBrush (output->d2d_context,
						 &stroke_color, NULL,
						 &stroke_brush);
  if (FAILED (hr) || !stroke_brush)
    return false;

  hr = ID2D1DeviceContext_CreateSolidColorBrush (output->d2d_context,
						 &fill_color, NULL,
						 &fill_brush);
  if (FAILED (hr) || !fill_brush)
    {
      ID2D1SolidColorBrush_Release (stroke_brush);
      return false;
    }

  if (!output->d2d_drawing)
    {
      ID2D1DeviceContext_BeginDraw (output->d2d_context);
      began_draw = true;
    }

  rect.left = (FLOAT) x;
  rect.top = (FLOAT) y;
  rect.right = (FLOAT) (x + w + 1);
  rect.bottom = (FLOAT) (y + h + 1);

  old_mode
    = ID2D1DeviceContext_GetAntialiasMode (output->d2d_context);
  ID2D1DeviceContext_SetAntialiasMode (output->d2d_context,
				       D2D1_ANTIALIAS_MODE_ALIASED);

  ID2D1DeviceContext_FillRectangle (output->d2d_context, &rect,
				    (ID2D1Brush *) fill_brush);
  ID2D1DeviceContext_DrawRectangle (output->d2d_context, &rect,
				    (ID2D1Brush *) stroke_brush, 1.0f,
				    NULL);

  ID2D1DeviceContext_SetAntialiasMode (output->d2d_context, old_mode);

  if (began_draw)
    {
      hr = ID2D1DeviceContext_EndDraw (output->d2d_context, NULL,
				       NULL);
      ok = SUCCEEDED (hr);
    }

  ID2D1SolidColorBrush_Release (fill_brush);
  ID2D1SolidColorBrush_Release (stroke_brush);
  return ok;
}

bool
w32_d2d_draw_polyline_dc (struct w32_output *output,
			  const POINT *points, int count,
			  COLORREF color, float thickness, int clip_x,
			  int clip_y, int clip_w, int clip_h)
{
  HRESULT hr;
  bool began_draw = false;
  bool ok = true;
  bool has_clip = false;
  ID2D1SolidColorBrush *brush = NULL;
  D2D1_RECT_F clip_rect;
  D2D1_ANTIALIAS_MODE old_mode;
  int i;

  if (!output || !output->d2d_context || !output->d2d_target)
    return false;

  if (!points)
    return false;

  if (count < 2)
    return true;

  if (thickness <= 0.0f)
    thickness = 1.0f;

  brush = w32_d2d_get_cached_brush (output, color);
  if (!brush)
    return false;

  if (!output->d2d_drawing)
    {
      ID2D1DeviceContext_BeginDraw (output->d2d_context);
      began_draw = true;
    }

  if (clip_w > 0 && clip_h > 0)
    {
      clip_rect.left = (FLOAT) clip_x;
      clip_rect.top = (FLOAT) clip_y;
      clip_rect.right = (FLOAT) (clip_x + clip_w);
      clip_rect.bottom = (FLOAT) (clip_y + clip_h);
      ID2D1DeviceContext_PushAxisAlignedClip (
	output->d2d_context, &clip_rect, D2D1_ANTIALIAS_MODE_ALIASED);
      has_clip = true;
    }

  old_mode
    = ID2D1DeviceContext_GetAntialiasMode (output->d2d_context);
  ID2D1DeviceContext_SetAntialiasMode (output->d2d_context,
				       D2D1_ANTIALIAS_MODE_ALIASED);

  for (i = 1; i < count; ++i)
    {
      D2D1_POINT_2F p0;
      D2D1_POINT_2F p1;

      p0.x = (FLOAT) points[i - 1].x;
      p0.y = (FLOAT) points[i - 1].y;
      p1.x = (FLOAT) points[i].x;
      p1.y = (FLOAT) points[i].y;

      ID2D1DeviceContext_DrawLine (output->d2d_context, p0, p1,
				   (ID2D1Brush *) brush, thickness,
				   NULL);
    }

  ID2D1DeviceContext_SetAntialiasMode (output->d2d_context, old_mode);

  if (has_clip)
    ID2D1DeviceContext_PopAxisAlignedClip (output->d2d_context);

  if (began_draw)
    {
      hr = ID2D1DeviceContext_EndDraw (output->d2d_context, NULL,
				       NULL);
      ok = SUCCEEDED (hr);
    }

  return ok;
}

/* ================================================================
   D2D frame lifecycle (begin / end / present)
   ================================================================ */

bool
w32_d2d_begin_frame (struct w32_output *output)
{
  if (!output || !output->d2d_context || !output->d2d_target)
    return false;

  output->d2d_stat_begin_frame_calls++;

  if (output->d2d_drawing)
    return true; /* Already in a frame.  */

  ID2D1DeviceContext_BeginDraw (output->d2d_context);
  output->d2d_drawing = 1;
  return true;
}

bool
w32_d2d_end_frame (struct w32_output *output)
{
  HRESULT hr;

  if (!output || !output->d2d_context || !output->d2d_drawing)
    return false;

  output->d2d_stat_end_frame_calls++;

  hr = ID2D1DeviceContext_EndDraw (output->d2d_context, NULL, NULL);
  output->d2d_drawing = 0;
  return SUCCEEDED (hr);
}

bool
w32_d2d_present (struct w32_output *output, bool allow_tearing)
{
  HRESULT hr;
  UINT flags = 0;
  UINT sync_interval = 0;

  if (!output || !output->dxgi_swap_chain)
    return false;

  /* End any outstanding D2D draw before presenting.  */
  if (output->d2d_drawing)
    w32_d2d_end_frame (output);

  /* Use tearing only if requested AND the swap chain supports it.  */
  if (allow_tearing && output->allow_tearing)
    {
      flags = DXGI_PRESENT_ALLOW_TEARING;
      sync_interval = 0;
    }

  hr = IDXGISwapChain1_Present (output->dxgi_swap_chain,
				sync_interval, flags);
  if (FAILED (hr))
    {
      /* Device lost or other error -- caller should fall back.  */
      output->d2d_stat_present_fail++;
      return false;
    }

  output->d2d_stat_present_ok++;

  return true;
}

/* ================================================================
   Lisp interface
   ================================================================ */

DEFUN ("w32-d2d-available-p", Fw32_d2d_available_p, Sw32_d2d_available_p,
       0, 0, 0,
       doc: /* Return non-nil if Direct2D/D3D11 rendering is available.
This checks whether D3D11 device and D2D1 factory were successfully initialized.  */)
(void)
{
  return (d3d11_device != NULL && d2d1_factory != NULL) ? Qt : Qnil;
}

DEFUN ("w32-d2d-frame-p", Fw32_d2d_frame_p, Sw32_d2d_frame_p,
       0, 1, 0,
       doc: /* Return non-nil if FRAME is using Direct2D rendering.
FRAME must be a live frame and defaults to the selected one.
Returns non-nil if the frame has an active D2D device context.  */)
(Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);

  if (!FRAME_W32_P (f))
    return Qnil;

  struct w32_output *output = FRAME_OUTPUT_DATA (f);
  if (output && output->d2d_context)
    return Qt;

  return Qnil;
}

DEFUN ("w32-d2d-frame-info", Fw32_d2d_frame_info, Sw32_d2d_frame_info,
       0, 1, 0, doc:
	 /* Return Direct2D rendering info for FRAME as an alist.
FRAME must be a live frame and defaults to the selected one.
Returns nil if D2D is not active for this frame.

The alist may contain:
`d2d-available' - t if D2D factory is initialized
`d2d-active' - t if this frame has a D2D context
`d3d-swap-chain' - t if using D3D11 swap chain (hardware accelerated)
*/)
(Lisp_Object frame)
{
  struct frame *f = decode_live_frame (frame);
  Lisp_Object result = Qnil;

  /* Add d3d-initialized status.  */
  result = Fcons (Fcons (intern ("d3d-initialized"),
			 d3d_initialized ? Qt : Qnil),
		  result);

  /* Add init trace.  */
  if (d3d_init_trace)
    result = Fcons (Fcons (intern ("d3d-init-trace"),
			   build_string (d3d_init_trace)),
		    result);

  /* Add syms_of_w32d3d trace.  */
  result
    = Fcons (Fcons (intern ("syms-trace"), build_string (syms_trace)),
	     result);

  /* Add swap-chain creation trace (global, last attempt).  */
  if (swap_chain_trace)
    result = Fcons (Fcons (intern ("d3d-swap-trace"),
			   build_string (swap_chain_trace)),
		    result);
  result = Fcons (Fcons (intern ("d3d-swap-hr-flip-discard"),
			 make_fixnum (
			   (EMACS_INT) swap_chain_hr_flip_discard)),
		  result);
  result = Fcons (Fcons (intern ("d3d-swap-hr-flip-sequential"),
			 make_fixnum ((
			   EMACS_INT) swap_chain_hr_flip_sequential)),
		  result);
  result = Fcons (Fcons (intern ("d3d-swap-hr-gdi-sequential"),
			 make_fixnum (
			   (EMACS_INT) swap_chain_hr_gdi_sequential)),
		  result);

  /* Add D2D output-target diagnostics (global, last attempt).  */
  if (d2d_output_trace)
    result = Fcons (Fcons (intern ("d2d-output-trace"),
			   build_string (d2d_output_trace)),
		    result);
  result
    = Fcons (Fcons (intern ("d2d-factory1-qi-hr"),
		    make_fixnum ((EMACS_INT) d2d_factory1_qi_hr)),
	     result);
  result
    = Fcons (Fcons (intern ("d2d-create-device-hr"),
		    make_fixnum ((EMACS_INT) d2d_create_device_hr)),
	     result);
  result
    = Fcons (Fcons (intern ("d2d-create-context-hr"),
		    make_fixnum ((EMACS_INT) d2d_create_context_hr)),
	     result);
  result
    = Fcons (Fcons (intern ("d2d-get-surface-hr"),
		    make_fixnum ((EMACS_INT) d2d_get_surface_hr)),
	     result);
  result
    = Fcons (Fcons (intern ("d2d-create-target-hr"),
		    make_fixnum ((EMACS_INT) d2d_create_target_hr)),
	     result);

  /* Add d3d11-device status (hardware acceleration).  */
  result = Fcons (Fcons (intern ("d3d11-device"),
			 d3d11_device ? Qt : Qnil),
		  result);

  /* Add d2d-factory status.  */
  result
    = Fcons (Fcons (intern ("d2d-factory"), d2d1_factory ? Qt : Qnil),
	     result);

  /* Add error messages if initialization failed (before frame check).
   */
  if (d3d_init_error)
    result = Fcons (Fcons (intern ("d3d-error"),
			   build_string (d3d_init_error)),
		    result);
  if (d2d_init_error)
    result = Fcons (Fcons (intern ("d2d-error"),
			   build_string (d2d_init_error)),
		    result);

  if (!FRAME_W32_P (f))
    return result;

  struct w32_output *output = FRAME_OUTPUT_DATA (f);

  /* Add d2d-active status.  */
  result = Fcons (Fcons (intern ("d2d-active"),
			 (output && output->d2d_context) ? Qt : Qnil),
		  result);

  /* Add frame-local render path flags.  */
  result
    = Fcons (Fcons (intern ("want-paint-buffer"),
		    (output && output->want_paint_buffer) ? Qt
							  : Qnil),
	     result);
  result = Fcons (Fcons (intern ("use-d3d"),
			 (output && output->use_d3d) ? Qt : Qnil),
		  result);
  result
    = Fcons (Fcons (intern ("d3d-direct-dc"),
		    (output && output->d3d_direct_dc) ? Qt : Qnil),
	     result);
  result = Fcons (Fcons (intern ("paint-dc"),
			 (output && output->paint_dc) ? Qt : Qnil),
		  result);

  /* Runtime sequencing counters.  */
  if (output)
    {
      result
	= Fcons (Fcons (intern ("d2d-stat-show-back-buffer-calls"),
			make_fixnum (
			  output->d2d_stat_show_back_buffer_calls)),
		 result);
      result
	= Fcons (Fcons (intern ("d2d-stat-update-begin"),
			make_fixnum (output->d2d_stat_update_begin)),
		 result);
      result = Fcons (Fcons (intern ("d2d-stat-update-begin-clear"),
			     make_fixnum (
			       output->d2d_stat_update_begin_clear)),
		      result);
      result = Fcons (Fcons (intern ("d2d-stat-update-end-flush"),
			     make_fixnum (
			       output->d2d_stat_update_end_flush)),
		      result);
      result = Fcons (Fcons (intern ("d2d-stat-up-to-date-flush"),
			     make_fixnum (
			       output->d2d_stat_up_to_date_flush)),
		      result);
      result = Fcons (Fcons (intern ("d2d-stat-unblocked-flush"),
			     make_fixnum (
			       output->d2d_stat_unblocked_flush)),
		      result);
      result = Fcons (Fcons (intern ("d2d-stat-flip-if-dirty-flush"),
			     make_fixnum (
			       output->d2d_stat_flip_if_dirty_flush)),
		      result);
      result = Fcons (Fcons (intern ("d2d-stat-begin-frame-calls"),
			     make_fixnum (
			       output->d2d_stat_begin_frame_calls)),
		      result);
      result = Fcons (Fcons (intern ("d2d-stat-end-frame-calls"),
			     make_fixnum (
			       output->d2d_stat_end_frame_calls)),
		      result);
      result
	= Fcons (Fcons (intern ("d2d-stat-present-ok"),
			make_fixnum (output->d2d_stat_present_ok)),
		 result);
      result
	= Fcons (Fcons (intern ("d2d-stat-present-fail"),
			make_fixnum (output->d2d_stat_present_fail)),
		 result);
    }

  /* Add d3d-swap-chain status.  */
  result
    = Fcons (Fcons (intern ("d3d-swap-chain"),
		    (output && output->dxgi_swap_chain) ? Qt : Qnil),
	     result);

  return result;
}

/* ================================================================
   Emacs init entry points
   ================================================================ */

/* syms_of_w32d3d -- called during dump to register Lisp primitives.
   This does NOT run when loading a dumped Emacs, so we cannot
   initialize D3D/D2D here.  */
void
syms_of_w32d3d (void)
{
  defsubr (&Sw32_d2d_available_p);
  defsubr (&Sw32_d2d_frame_p);
  defsubr (&Sw32_d2d_frame_info);
}

/* init_w32d3d -- called at runtime to initialize D3D11/D2D.
   This runs both during dumping AND when loading a dumped Emacs,
   so D3D/D2D initialization happens here.  */
void
init_w32d3d (void)
{
  d3d_init_trace = "init-entered";
  w32_d3d_init ();
  d3d_init_trace = "init-d3d-done";
  w32_d2d_init ();
  d3d_init_trace = "init-complete";
}

#endif /* HAVE_NTGUI */
