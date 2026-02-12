# AGENTS.md - Guidelines for AI Coding Agents

This document provides instructions for AI agents working on GNU Emacs source code.

## Build Commands

### Full Build (Windows with MSYS2/MinGW-w64)
```bash
# From emacs-build root directory (not git/master)
# IMPORTANT: Always set MSYSTEM=UCRT64 to ensure the correct toolchain.
# The shell may inherit MSYSTEM=MINGW64, which silently builds into the
# wrong directory (master-mingw-w64-x86_64 instead of master-mingw-w64-ucrt-x86_64).
MSYSTEM=UCRT64 ./emacs-build.cmd --branch master --slim --build

# Or using MSYS2 shell directly
MSYSTEM=UCRT64 ./scripts/msys2.cmd -c "./emacs-build.sh --branch master --slim --build"
```

### Standard Unix Build
```bash
./autogen.sh          # Only needed for Git checkouts
./configure --prefix=/path/to/install
make -j$(nproc)       # Parallel build using all cores
make install
```

### Syntax-Check Individual C Files (Windows)
```bash
# Use MSYS2 GCC for quick syntax validation without full build
"Q:\repos\emacs-build\msys64\ucrt64\bin\gcc.exe" -fsyntax-only -c \
  -I"build/master-mingw-w64-ucrt-x86_64/src" \
  -I"build/master-mingw-w64-ucrt-x86_64/lib" \
  -I"git/master/src" -I"git/master/lib" \
  -DHAVE_CONFIG_H "git/master/src/<file>.c"
```

## Optimizing Build Time During Development

**IMPORTANT**: The configure step is very slow (~5-10 minutes).  Minimize
reconfiguration by following these guidelines:

### Avoid Reconfiguration
- **Use `--build-dev` instead of `--build`** - skips configure, runs make only
- Configure is only needed when: `configure.ac` changes, new dependencies added,
  or build directory is missing/corrupted
- After initial configure, use incremental builds

### Incremental Build (after initial configure)
```bash
# From emacs-build root directory (not git/master)
# Use --without-native-compilation to skip native comp and speed up dev builds.
MSYSTEM=UCRT64 ./emacs-build.cmd --branch master --slim --without-native-compilation --build-dev

# Or using MSYS2 shell directly
MSYSTEM=UCRT64 ./scripts/msys2.cmd -c "./emacs-build.sh --branch master --slim --without-native-compilation --build-dev"
```

### Development Workflow
1. **First time**: Run full `--build` to configure and compile
2. **Edit C files**: Use syntax-check (above) for quick validation
3. **Compile changes**: Run `--build-dev` (skips configure, much faster)
4. **Only use `--build`** if configure.ac or dependencies change

### Quick Syntax Check Before Full Build
Always syntax-check modified files before running make to catch errors fast:
```bash
# Check multiple files in parallel
for f in w32term.c w32.c w32proc.c; do
  "Q:\repos\emacs-build\msys64\ucrt64\bin\gcc.exe" -fsyntax-only -c \
    -I"build/master-mingw-w64-ucrt-x86_64/src" \
    -I"build/master-mingw-w64-ucrt-x86_64/lib" \
    -I"git/master/src" -I"git/master/lib" \
    -DHAVE_CONFIG_H "git/master/src/$f" &
done
wait
```

## Testing

### Run All Tests
```bash
make check                    # Standard tests (from test/ directory)
make check-expensive          # Include expensive tests
make check-all                # All tests including unstable
```

### Run Single Test File
```bash
make <filename>-tests         # e.g., make files-tests
make lisp/files-tests         # With path
make <filename> SELECTOR='test-name'  # Run specific test
```

### Run Tests with Selector
```bash
make <filename> SELECTOR='"pattern$$"'     # Regex pattern
make <filename> SELECTOR='test-foo-remote' # Specific test name
```

### ERT in Batch Mode
```bash
emacs --batch -l test/lisp/foo-tests.el -f ert-run-tests-batch-and-exit
```

## Code Style Guidelines

### C Code Style
- **Indentation**: 2 spaces, no tabs in code (tabs in Makefiles only)
- **Line length**: Max 79 characters for code, 63 preferred for ChangeLog
- **Braces**: GNU style - braces on their own lines for function definitions
- **Comments**: Use `/* */` style, explain *why* not *what*

```c
/* Cache drive types to avoid repeated GetDriveType calls.
   Drive letters A-Z map to indices 0-25.  */
static UINT drive_type_cache[26];

static bool
is_slow_fs (const char *name)
{
  /* Implementation with early returns.  */
  if (!name || !name[0])
    return false;

  int drive_idx = -1;
  if (name[1] == ':')
    drive_idx = (name[0] | 0x20) - 'a';
  ...
}
```

### Emacs Lisp Style
- **Indentation**: 2 spaces, managed by `lisp-indent-function`
- **Docstrings**: Required for all public functions, first line is summary
- **Naming**: Use `package-name-` prefix for all symbols
- Use `checkdoc` to validate documentation

```elisp
(defun w32-perf-run-all ()
  "Run all Windows performance benchmarks and display results.
Returns an alist of benchmark results."
  (interactive)
  ...)
```

### General Conventions
- American English spelling ("behavior" not "behaviour")
- Two spaces between sentences in comments/docs
- UTF-8 encoding for all source files
- LF line endings (Unix-style) for all files in this repository

## Commit Messages

Format:
```
Summary line (50 chars max, no period)

Optional body explaining the *why* (wrap at 63-78 chars).

* file1.el (function-name): Change description.
* file2.c (another_function): Another change.
(Bug#NNNNN)
```

- Use present tense ("Add feature" not "Added feature")
- Reference bugs with `(Bug#NNNNN)` format
- Start with "; " to skip ChangeLog generation for trivial changes

## File Organization

```
src/           C source code
lisp/          Emacs Lisp source
test/          Test files (ERT tests)
  lisp/        Tests for lisp/ files
  src/         Tests for src/ files
  manual/      Manual/interactive tests
etc/           Documentation, NEWS, tutorials
admin/         Maintenance scripts and notes
  notes/       Developer documentation
nt/            Windows-specific files and docs
```

## Windows-Specific Development

### Key Files for W32 Performance
- `src/w32.c` - Core Windows utilities, file operations
- `src/w32proc.c` - Process/subprocess handling, pipes
- `src/w32term.c` - Terminal/display, GDI operations
- `src/w32font.c` - Font rendering
- `src/w32term.h` - Shared declarations

### Performance Benchmarks
```bash
# Run W32 performance benchmarks
emacs --batch -l test/manual/w32-perf-bench.el -f w32-perf-run-all
```

### Common Optimizations
1. **Cache expensive Windows API calls** (GetVolumeInformation, GetDriveType)
2. **Increase pipe buffer sizes** for subprocess I/O (default 64KB)
3. **Cache GDI objects** (brushes, pens) to reduce Create/Delete overhead

## Error Handling

### C Code
- Check return values explicitly
- Use `emacs_abort()` for unrecoverable errors
- Set `errno` appropriately for system call wrappers

### Emacs Lisp
- Use `condition-case` for recoverable errors
- Signal errors with `error` or `user-error`
- Use `unwind-protect` for cleanup

## Important Notes

- **Do not merge to master manually** - let gitmerge handle branch syncing
- **Test on release branch** if fixing bugs in current release
- **Document in etc/NEWS** for user-visible changes
- **Add `:version` tag** to new defcustom/defface definitions
- **Run `make check`** before committing significant changes

## Resources

- `CONTRIBUTE` - Detailed contribution guidelines
- `admin/notes/` - Various developer notes
- `etc/DEBUG` - Debugging instructions
- `nt/INSTALL.W64` - Windows build instructions
- `test/README` - Testing documentation
