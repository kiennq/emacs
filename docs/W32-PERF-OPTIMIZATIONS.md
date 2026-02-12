# Windows Performance Optimizations for Emacs

This document describes the Windows-specific performance optimizations
implemented in this Emacs build.

## Overview

Emacs on Windows has historically been slower than on Linux/macOS due to
differences in system APIs and their performance characteristics. These
optimizations target the most significant bottlenecks identified through
profiling.

## Optimizations

### 1. Increased Default Pipe Buffer Size

**File:** `src/w32proc.c`

**Change:** Default `w32_pipe_buffer_size` increased from 0 (4KB OS default)
to 65536 (64KB).

**Rationale:** Subprocess communication (LSP servers, compilation, grep,
shell commands) involves frequent I/O through pipes. The default 4KB buffer
causes excessive context switches. A 64KB buffer significantly reduces
overhead while maintaining reasonable memory usage.

**Impact:** Improved subprocess I/O throughput, especially noticeable with:
- LSP servers (eglot, lsp-mode)
- Compilation buffers
- grep/ripgrep operations
- Shell command execution

### 2. Extended Volume Information Cache

**File:** `src/w32.c`

**Change:** `VOLINFO_CACHE_TIMEOUT` increased from 10 seconds to 60 seconds.

**Rationale:** `GetVolumeInformation()` is an expensive Windows API call
(5-10ms for network drives). Since volume properties rarely change during
a typical editing session, caching results for 60 seconds eliminates
repeated expensive calls.

**Impact:** Faster file operations, especially on network drives.

### 3. Drive Type Cache for is_slow_fs()

**File:** `src/w32.c`

**Change:** Added `drive_type_cache[26]` array to cache `GetDriveType()`
results in the `is_slow_fs()` function.

**Rationale:** `is_slow_fs()` is called on every `stat()` operation to
determine if a path is on a slow filesystem (network, CD-ROM). Since
drive types never change during runtime, caching eliminates repeated
system calls.

**Impact:** Faster `file-attributes`, `file-exists-p`, and related
operations.

### 4. GDI Brush Cache

**Files:** `src/w32term.c`, `src/w32term.h`, `src/w32font.c`

**Change:** Implemented `w32_get_brush()` with a 16-entry ring buffer
cache for `CreateSolidBrush()` results.

**Rationale:** `CreateSolidBrush()` and `DeleteObject()` are expensive
GDI operations called thousands of times during redisplay. Most text
uses only a few colors, so caching brushes eliminates redundant GDI calls.

**Impact:** Faster text rendering and scrolling, reduced GDI overhead.

## Benchmarking

A synthetic benchmark suite is provided at:
`test/manual/w32-perf-bench.el`

### Running Benchmarks

**Batch mode:**
```bash
emacs --batch -l test/manual/w32-perf-bench.el -f w32-perf-run-all
```

**Interactive:**
```
M-x w32-perf-run-all
```

**Quick test (fewer iterations):**
```
M-x w32-perf-run-quick
```

### Benchmark Components

1. **subprocess-io** - Tests pipe buffer optimization
2. **file-stat** - Tests drive type cache
3. **directory-stat** - Tests volume cache + drive type cache
4. **mixed-file-ops** - Tests all file optimizations together
5. **process-creation** - Tests subprocess overhead
6. **redisplay** - Tests GDI brush cache (GUI mode only)

### Comparing Results

To compare before/after performance:

```elisp
;; Run on unoptimized build, save results
(setq before-results (w32-perf-run-all))

;; Run on optimized build
(setq after-results (w32-perf-run-all))

;; Compare
(w32-perf-compare before-results after-results)
```

## Configuration Variables

### w32-pipe-buffer-size

The pipe buffer size can be adjusted via:
```elisp
(setq w32-pipe-buffer-size 131072)  ; 128KB
```

Default: 65536 (64KB)
Range: 0 (4KB OS default) to 1048576 (1MB)

## Future Optimizations

Potential areas for further optimization:

1. **Font metrics caching** - Cache font dimension lookups
2. **DC operation batching** - Batch multiple DC operations in tight loops
3. **Compiler flags** - More aggressive optimization (-O3, LTO)
4. **Thread pool for I/O** - Async file operations

## Testing

These changes have been tested with:
- GCC 15.2.0 (MSYS2 UCRT64)
- Windows 10/11
- Both GUI and terminal modes

All changes are backward compatible and do not affect Emacs behavior,
only performance.
