;;; w32-perf-bench.el --- Windows performance benchmarks -*- lexical-binding: t -*-

;; Copyright (C) 2026 Free Software Foundation, Inc.

;; Author: Emacs Contributors
;; Keywords: benchmark, performance, w32

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Synthetic benchmarks to measure Windows-specific performance optimizations:
;;
;; File/Process benchmarks (work in --batch mode):
;;   1. Subprocess I/O throughput - tests pipe buffer size optimization
;;   2. File stat operations - tests drive type cache
;;   3. Directory stat - tests volume info cache + drive type cache
;;   4. Mixed file operations - tests all file optimizations together
;;   5. Process creation - tests general subprocess performance
;;
;; GUI display benchmarks (require graphic display):
;;   6. Redisplay - tests GDI brush cache
;;   7. Scroll stress - tests pen/brush cache, glyph/scroll clip HRGNs
;;   8. Cursor motion - tests brush cache, clip regions, hollow cursor
;;   9. Wavy underlines - tests pen cache (w32_get_pen)
;;  10. Image display - tests image CompatibleDC cache, brush fixups
;;
;; Run with: emacs --batch -l test/manual/w32-perf-bench.el -f w32-perf-run-all
;; GUI only: emacs -l test/manual/w32-perf-bench.el -f w32-perf-run-gui
;;
;; Or interactively: M-x w32-perf-run-all  /  M-x w32-perf-run-gui

;;; Code:

(require 'benchmark)
(require 'cl-lib)

(defvar w32-perf-results nil
  "Alist of benchmark results: ((name . time) ...).")

(defvar w32-perf-iterations 5
  "Number of iterations for each benchmark.")

(defvar w32-perf-verbose t
  "Whether to print progress messages.")

(defun w32-perf-message (fmt &rest args)
  "Print message if `w32-perf-verbose' is non-nil."
  (when w32-perf-verbose
    (apply #'message fmt args)))

(defun w32-perf-record (name time)
  "Record benchmark result NAME with TIME."
  (push (cons name time) w32-perf-results)
  (w32-perf-message "  %s: %.4f seconds" name time))

;;; ---------------------------------------------------------------------------
;;; Benchmark 1: Subprocess I/O Throughput
;;; Tests: Pipe buffer size optimization (w32_pipe_buffer_size = 64KB)
;;; ---------------------------------------------------------------------------

(defun w32-perf-subprocess-io-single ()
  "Single run of subprocess I/O benchmark."
  (let* ((data-size (* 1024 1024))  ; 1 MB of data
         (chunk "0123456789ABCDEF") ; 16 bytes
         (chunks (/ data-size (length chunk)))
         (input (apply #'concat (make-list chunks chunk))))
    ;; Use 'cat' equivalent on Windows (cmd /c type CON doesn't work well)
    ;; Use findstr with /R for regex that matches everything
    (with-temp-buffer
      (let ((proc (if (eq system-type 'windows-nt)
                      (start-process "bench" (current-buffer) "cmd" "/c" "findstr" ".*")
                    (start-process "bench" (current-buffer) "cat"))))
        (process-send-string proc input)
        (process-send-eof proc)
        (while (process-live-p proc)
          (accept-process-output proc 0.01))
        (buffer-size)))))

(defun w32-perf-subprocess-io ()
  "Benchmark subprocess I/O throughput.
Tests the pipe buffer optimization by sending data through a subprocess."
  (w32-perf-message "Running subprocess I/O benchmark...")
  (let ((total-time 0)
        (iterations 3)) ; fewer iterations as this is slower
    (dotimes (_ iterations)
      (garbage-collect)
      (setq total-time (+ total-time (benchmark-elapse (w32-perf-subprocess-io-single)))))
    (w32-perf-record "subprocess-io" (/ total-time iterations))))

;;; ---------------------------------------------------------------------------
;;; Benchmark 2: File Stat Operations
;;; Tests: Drive type cache in is_slow_fs()
;;; ---------------------------------------------------------------------------

(defun w32-perf-file-stat-single ()
  "Single run of file stat benchmark."
  (let ((dir (if (eq system-type 'windows-nt)
                 "c:/"
               "/")))
    ;; Stat the root directory many times
    (dotimes (_ 10000)
      (file-attributes dir)
      (file-directory-p dir)
      (file-readable-p dir))))

(defun w32-perf-file-stat ()
  "Benchmark file stat operations.
Tests the drive type cache optimization."
  (w32-perf-message "Running file stat benchmark...")
  (let ((total-time 0))
    (dotimes (_ w32-perf-iterations)
      (garbage-collect)
      (setq total-time (+ total-time (benchmark-elapse (w32-perf-file-stat-single)))))
    (w32-perf-record "file-stat" (/ total-time w32-perf-iterations))))

;;; ---------------------------------------------------------------------------
;;; Benchmark 3: Directory Listing with Stats
;;; Tests: Volume info cache + drive type cache
;;; ---------------------------------------------------------------------------

(defun w32-perf-directory-stat-single ()
  "Single run of directory stat benchmark."
  (let* ((dir (if (eq system-type 'windows-nt)
                  (or (getenv "TEMP") "c:/Windows/Temp")
                (or (getenv "TMPDIR") "/tmp")))
         (files (and (file-directory-p dir)
                     (directory-files dir t nil t))))
    ;; Stat all files in temp directory multiple times
    (dotimes (_ 50)
      (dolist (f (seq-take files 100))
        (file-attributes f)))))

(defun w32-perf-directory-stat ()
  "Benchmark directory listing with stat calls.
Tests volume info cache and drive type cache together."
  (w32-perf-message "Running directory stat benchmark...")
  (let ((total-time 0))
    (dotimes (_ w32-perf-iterations)
      (garbage-collect)
      (setq total-time (+ total-time (benchmark-elapse (w32-perf-directory-stat-single)))))
    (w32-perf-record "directory-stat" (/ total-time w32-perf-iterations))))

;;; ---------------------------------------------------------------------------
;;; Benchmark 4: Redisplay Simulation
;;; Tests: GDI brush cache
;;; ---------------------------------------------------------------------------

(defun w32-perf-redisplay-single ()
  "Single run of redisplay benchmark."
  (let ((buf (generate-new-buffer "*perf-test*")))
    (unwind-protect
        (with-current-buffer buf
          ;; Insert colorful content
          (dotimes (i 1000)
            (insert (propertize (format "Line %d: The quick brown fox jumps over the lazy dog\n" i)
                                'face (nth (mod i 10)
                                           '(font-lock-keyword-face
                                             font-lock-string-face
                                             font-lock-comment-face
                                             font-lock-function-name-face
                                             font-lock-variable-name-face
                                             font-lock-type-face
                                             font-lock-constant-face
                                             font-lock-builtin-face
                                             font-lock-warning-face
                                             font-lock-preprocessor-face)))))
          ;; Force redisplay multiple times by scrolling
          (when (display-graphic-p)
            (switch-to-buffer buf)
            (dotimes (_ 20)
              (goto-char (point-min))
              (redisplay t)
              (goto-char (point-max))
              (redisplay t))))
      (kill-buffer buf))))

(defun w32-perf-redisplay ()
  "Benchmark redisplay operations.
Tests the GDI brush cache optimization.
Note: Most effective when run in GUI mode, not --batch."
  (w32-perf-message "Running redisplay benchmark...")
  (if (display-graphic-p)
      (let ((total-time 0))
        (dotimes (_ w32-perf-iterations)
          (garbage-collect)
          (setq total-time (+ total-time (benchmark-elapse (w32-perf-redisplay-single)))))
        (w32-perf-record "redisplay" (/ total-time w32-perf-iterations)))
    (w32-perf-message "  Skipping redisplay benchmark (not in GUI mode)")))

;;; ---------------------------------------------------------------------------
;;; Benchmark 5: Mixed File Operations
;;; Tests: All file-related optimizations together
;;; ---------------------------------------------------------------------------

(defun w32-perf-mixed-file-ops-single ()
  "Single run of mixed file operations benchmark."
  (let* ((temp-dir (make-temp-file "emacs-perf-" t))
         (files nil))
    (unwind-protect
        (progn
          ;; Create files
          (dotimes (i 100)
            (let ((f (expand-file-name (format "test-%d.txt" i) temp-dir)))
              (push f files)
              (with-temp-file f
                (insert (make-string 1000 ?x)))))
          ;; Stat all files multiple times
          (dotimes (_ 20)
            (dolist (f files)
              (file-attributes f)
              (file-readable-p f)
              (file-writable-p f)))
          ;; Read files
          (dolist (f files)
            (with-temp-buffer
              (insert-file-contents f)))
          ;; Delete files
          (dolist (f files)
            (delete-file f)))
      ;; Cleanup
      (ignore-errors (delete-directory temp-dir t)))))

(defun w32-perf-mixed-file-ops ()
  "Benchmark mixed file operations.
Tests all file-related optimizations in a realistic scenario."
  (w32-perf-message "Running mixed file operations benchmark...")
  (let ((total-time 0)
        (iterations 3)) ; fewer iterations as this creates files
    (dotimes (_ iterations)
      (garbage-collect)
      (setq total-time (+ total-time (benchmark-elapse (w32-perf-mixed-file-ops-single)))))
    (w32-perf-record "mixed-file-ops" (/ total-time iterations))))

;;; ---------------------------------------------------------------------------
;;; Benchmark 6: Process Creation Overhead
;;; Tests: General subprocess performance
;;; ---------------------------------------------------------------------------

(defun w32-perf-process-creation-single ()
  "Single run of process creation benchmark."
  (dotimes (_ 50)
    (let ((proc (if (eq system-type 'windows-nt)
                    (start-process "bench" nil "cmd" "/c" "echo" "test")
                  (start-process "bench" nil "echo" "test"))))
      (while (process-live-p proc)
        (accept-process-output proc 0.001)))))

(defun w32-perf-process-creation ()
  "Benchmark process creation overhead."
  (w32-perf-message "Running process creation benchmark...")
  (let ((total-time 0))
    (dotimes (_ w32-perf-iterations)
      (garbage-collect)
      (setq total-time (+ total-time (benchmark-elapse (w32-perf-process-creation-single)))))
    (w32-perf-record "process-creation" (/ total-time w32-perf-iterations))))

;;; ---------------------------------------------------------------------------
;;; Benchmark 7: Heavy Scrolling (Redisplay Stress Test)
;;; Tests: Pen cache, brush cache, glyph clip HRGNs, scroll clip HRGNs
;;; ---------------------------------------------------------------------------

(defun w32-perf-scroll-stress-single ()
  "Single run of heavy scrolling benchmark.
Scrolls rapidly through a large buffer with mixed faces to stress
pen cache, brush cache, and clip region reuse."
  (let ((buf (generate-new-buffer "*scroll-stress*")))
    (unwind-protect
        (with-current-buffer buf
          ;; Fill buffer with diverse content using many different faces
          (dotimes (i 5000)
            (let ((face (nth (mod i 10)
                             '(font-lock-keyword-face
                               font-lock-string-face
                               font-lock-comment-face
                               font-lock-function-name-face
                               font-lock-variable-name-face
                               font-lock-type-face
                               font-lock-constant-face
                               font-lock-builtin-face
                               font-lock-warning-face
                               font-lock-preprocessor-face))))
              (insert (propertize
                       (format "Line %04d: abcdefghij ABCDEFGHIJ 0123456789\n" i)
                       'face face))))
          (when (display-graphic-p)
            (switch-to-buffer buf)
            ;; Scroll line-by-line rapidly (exercises scroll_run clip regions)
            (goto-char (point-min))
            (dotimes (_ 200)
              (scroll-up 1)
              (redisplay t))
            ;; Scroll page-by-page (exercises different scroll amounts)
            (goto-char (point-min))
            (dotimes (_ 50)
              (scroll-up (/ (window-body-height) 2))
              (redisplay t))
            ;; Random positions (exercises full redisplay with brush/pen)
            (dotimes (_ 50)
              (goto-char (1+ (random (point-max))))
              (recenter)
              (redisplay t))))
      (kill-buffer buf))))

(defun w32-perf-scroll-stress ()
  "Benchmark heavy scrolling performance.
Tests pen cache, brush cache, glyph clip HRGNs, and scroll clip HRGNs.
Must run in GUI mode."
  (w32-perf-message "Running scroll stress benchmark...")
  (if (display-graphic-p)
      (let ((total-time 0))
        (dotimes (_ w32-perf-iterations)
          (garbage-collect)
          (setq total-time (+ total-time (benchmark-elapse
                                          (w32-perf-scroll-stress-single)))))
        (w32-perf-record "scroll-stress" (/ total-time w32-perf-iterations)))
    (w32-perf-message "  Skipping scroll stress benchmark (not in GUI mode)")))

;;; ---------------------------------------------------------------------------
;;; Benchmark 8: Cursor Motion (Rapid Redisplay)
;;; Tests: Brush cache, clip regions, hollow cursor brush optimization
;;; ---------------------------------------------------------------------------

(defun w32-perf-cursor-motion-single ()
  "Single run of cursor motion benchmark.
Moves cursor rapidly across a buffer forcing many small redisplays."
  (let ((buf (generate-new-buffer "*cursor-motion*")))
    (unwind-protect
        (with-current-buffer buf
          (dotimes (i 500)
            (insert (format "Line %d with some text content here.\n" i)))
          (when (display-graphic-p)
            (switch-to-buffer buf)
            ;; Forward char by char
            (goto-char (point-min))
            (dotimes (_ 2000)
              (forward-char 1)
              (redisplay t))
            ;; Line by line
            (goto-char (point-min))
            (dotimes (_ 400)
              (forward-line 1)
              (redisplay t))
            ;; Word by word
            (goto-char (point-min))
            (dotimes (_ 500)
              (forward-word 1)
              (redisplay t))))
      (kill-buffer buf))))

(defun w32-perf-cursor-motion ()
  "Benchmark rapid cursor motion with redisplay.
Tests brush cache, clip regions, and hollow cursor optimization.
Must run in GUI mode."
  (w32-perf-message "Running cursor motion benchmark...")
  (if (display-graphic-p)
      (let ((total-time 0))
        (dotimes (_ w32-perf-iterations)
          (garbage-collect)
          (setq total-time (+ total-time (benchmark-elapse
                                          (w32-perf-cursor-motion-single)))))
        (w32-perf-record "cursor-motion" (/ total-time w32-perf-iterations)))
    (w32-perf-message "  Skipping cursor motion benchmark (not in GUI mode)")))

;;; ---------------------------------------------------------------------------
;;; Benchmark 9: Wavy Underline Rendering
;;; Tests: Pen cache (used by w32_draw_underwave)
;;; ---------------------------------------------------------------------------

(defun w32-perf-underwave-single ()
  "Single run of wavy underline benchmark.
Creates a buffer with many underlined words to stress pen cache."
  (let ((buf (generate-new-buffer "*underwave*")))
    (unwind-protect
        (with-current-buffer buf
          (dotimes (i 2000)
            (insert (propertize (format "error_%d " i)
                                'face '((:underline (:style wave :color "red"))))
                    (propertize (format "warn_%d " i)
                                'face '((:underline (:style wave :color "orange"))))
                    (propertize (format "info_%d " i)
                                'face '((:underline (:style wave :color "blue"))))
                    "\n"))
          (when (display-graphic-p)
            (switch-to-buffer buf)
            (goto-char (point-min))
            (dotimes (_ 100)
              (scroll-up 1)
              (redisplay t))))
      (kill-buffer buf))))

(defun w32-perf-underwave ()
  "Benchmark wavy underline rendering.
Tests pen cache (w32_get_pen) used by w32_draw_underwave.
Must run in GUI mode."
  (w32-perf-message "Running wavy underline benchmark...")
  (if (display-graphic-p)
      (let ((total-time 0))
        (dotimes (_ w32-perf-iterations)
          (garbage-collect)
          (setq total-time (+ total-time (benchmark-elapse
                                          (w32-perf-underwave-single)))))
        (w32-perf-record "underwave" (/ total-time w32-perf-iterations)))
    (w32-perf-message "  Skipping underwave benchmark (not in GUI mode)")))

;;; ---------------------------------------------------------------------------
;;; Benchmark 10: Image Display
;;; Tests: Image CompatibleDC cache, image mask DC cache, brush fixups
;;; ---------------------------------------------------------------------------

(defun w32-perf-image-display-single ()
  "Single run of image display benchmark.
Creates an XPM image and displays it many times to stress
image DC and brush caching."
  (let ((buf (generate-new-buffer "*image-display*"))
        ;; A small XPM image for testing
        (xpm-data "/* XPM */
static char * test_xpm[] = {
\"16 16 2 1\",
\"  c None\",
\". c #FF0000\",
\"                \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\" .............. \",
\"                \"};"))
    (unwind-protect
        (with-current-buffer buf
          ;; Insert many images
          (dotimes (i 200)
            (insert-image (create-image xpm-data 'xpm t))
            (when (= (mod i 20) 19)
              (insert "\n")))
          (when (display-graphic-p)
            (switch-to-buffer buf)
            ;; Scroll through images
            (goto-char (point-min))
            (dotimes (_ 50)
              (scroll-up 1)
              (redisplay t))))
      (kill-buffer buf))))

(defun w32-perf-image-display ()
  "Benchmark image display performance.
Tests image CompatibleDC cache and brush cache in image drawing.
Must run in GUI mode."
  (w32-perf-message "Running image display benchmark...")
  (if (display-graphic-p)
      (let ((total-time 0))
        (dotimes (_ w32-perf-iterations)
          (garbage-collect)
          (setq total-time (+ total-time (benchmark-elapse
                                          (w32-perf-image-display-single)))))
        (w32-perf-record "image-display" (/ total-time w32-perf-iterations)))
    (w32-perf-message "  Skipping image display benchmark (not in GUI mode)")))

;;; ---------------------------------------------------------------------------
;;; Main Entry Points
;;; ---------------------------------------------------------------------------

(defun w32-perf-run-all ()
  "Run all Windows performance benchmarks and display results."
  (interactive)
  (setq w32-perf-results nil)
  (w32-perf-message "")
  (w32-perf-message "=== Windows Performance Benchmarks ===")
  (w32-perf-message "Platform: %s" system-type)
  (w32-perf-message "Emacs version: %s" emacs-version)
  (w32-perf-message "GUI: %s" (if (display-graphic-p) "yes" "no (batch mode)"))
  (w32-perf-message "")

  ;; File and I/O benchmarks (work in batch mode)
  (w32-perf-file-stat)
  (w32-perf-directory-stat)
  (w32-perf-mixed-file-ops)
  (w32-perf-process-creation)
  (w32-perf-subprocess-io)

  ;; GUI display benchmarks (require graphic display)
  (w32-perf-redisplay)
  (w32-perf-scroll-stress)
  (w32-perf-cursor-motion)
  (w32-perf-underwave)
  (w32-perf-image-display)

  ;; Summary
  (w32-perf-message "")
  (w32-perf-message "=== Summary ===")
  (let ((total 0))
    (dolist (result (reverse w32-perf-results))
      (setq total (+ total (cdr result)))
      (w32-perf-message "%-20s %8.4f sec" (car result) (cdr result)))
    (w32-perf-message "%-20s %8.4f sec" "TOTAL" total))

  ;; Return results for programmatic use
  w32-perf-results)

(defun w32-perf-run-gui ()
  "Run only GUI-related benchmarks (Phase 1 optimizations).
Must be run in GUI mode (not --batch)."
  (interactive)
  (unless (display-graphic-p)
    (error "GUI benchmarks require a graphic display; don't use --batch"))
  (setq w32-perf-results nil)
  (w32-perf-message "")
  (w32-perf-message "=== GUI Display Benchmarks ===")
  (w32-perf-message "Platform: %s" system-type)
  (w32-perf-message "Emacs version: %s" emacs-version)
  (w32-perf-message "")

  (w32-perf-redisplay)
  (w32-perf-scroll-stress)
  (w32-perf-cursor-motion)
  (w32-perf-underwave)
  (w32-perf-image-display)

  (w32-perf-message "")
  (w32-perf-message "=== Results ===")
  (let ((total 0))
    (dolist (result (reverse w32-perf-results))
      (setq total (+ total (cdr result)))
      (w32-perf-message "%-20s %8.4f sec" (car result) (cdr result)))
    (w32-perf-message "%-20s %8.4f sec" "TOTAL" total))
  w32-perf-results)

(defun w32-perf-run-quick ()
  "Run a quick subset of benchmarks for rapid testing."
  (interactive)
  (setq w32-perf-results nil)
  (let ((w32-perf-iterations 2))
    (w32-perf-message "")
    (w32-perf-message "=== Quick Performance Test ===")
    (w32-perf-file-stat)
    (w32-perf-directory-stat)
    (w32-perf-message "")
    (w32-perf-message "=== Results ===")
    (dolist (result (reverse w32-perf-results))
      (w32-perf-message "%-20s %8.4f sec" (car result) (cdr result))))
  w32-perf-results)

(defun w32-perf-compare (before-results after-results)
  "Compare BEFORE-RESULTS and AFTER-RESULTS and print improvement."
  (w32-perf-message "")
  (w32-perf-message "=== Performance Comparison ===")
  (w32-perf-message "%-20s %10s %10s %10s" "Benchmark" "Before" "After" "Speedup")
  (w32-perf-message (make-string 52 ?-))
  (dolist (before before-results)
    (let* ((name (car before))
           (before-time (cdr before))
           (after-time (cdr (assoc name after-results))))
      (when after-time
        (let ((speedup (/ before-time after-time)))
          (w32-perf-message "%-20s %10.4f %10.4f %9.2fx"
                            name before-time after-time speedup))))))

;; Auto-run in batch mode
(when noninteractive
  (w32-perf-run-all)
  (kill-emacs 0))

(provide 'w32-perf-bench)
;;; w32-perf-bench.el ends here
