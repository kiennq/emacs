;;; igc-tests.el --- tests for src/igc.c  -*- lexical-binding: t -*-

;; Copyright (C) 2024-2025 Free Software Foundation, Inc.

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

;;; Code:

(require 'ert)
(require 'filenotify)

(declare-function igc--set-commit-limit "igc.c")
(declare-function igc--set-pause-time "igc.c")
(declare-function igc-info "igc.c")

(ert-deftest set-commit-limit-test ()
  :tags '(:igc)
  (should (equal (igc--set-commit-limit (ash 1 30)) nil))
  (should (equal (assoc-string "commit-limit" (igc-info))
                 '("commit-limit" nil #x40000000 nil)))
  (should-error (igc--set-commit-limit -1)
                :type 'args-out-of-range)
  (should-error (igc--set-commit-limit
                 (if (< #x1fffffff most-positive-fixnum)
                     (- (ash 1 64) 1)
                   (- (ash 1 32) 1))
                :type 'args-out-of-range))
  (should (equal (igc--set-commit-limit nil) nil))
  (should (member (assoc-string "commit-limit" (igc-info))
                  '(("commit-limit" nil #xffffffff nil)
                    ("commit-limit" nil #xffffffffffffffff nil)))))

(ert-deftest set-pause-time-test ()
  :tags '(:igc)
  (should (equal (igc--set-pause-time 0.5) nil))
  (should (equal (assoc-string "pause-time" (igc-info))
                 '("pause-time" nil 0.5 nil)))
  (should-error (igc--set-pause-time -1) :type 'range-error)
  (should (equal (igc--set-pause-time 1.0e+INF) nil))
  (should (equal (assoc-string "pause-time" (igc-info))
                 '("pause-time" nil 1.0e+INF nil)))
  (should (equal (igc--set-pause-time 0.01) nil)))

(defvar igc-test--list-length 16000000
  "Number of cons cells we created to trigger incremental GC.")

(defun igc-test--trigger-incremental-gc ()
  "Attempt to trigger incremental garbage collection."
  (ignore (make-list igc-test--list-length nil)))

;; Test whether triggering incremental GC from a secondary thread aborts
;; the main thread.  This will cause an abort on unfixed Emacs versions
;; on GNU/Linux with the message "The futex facility returned an
;; unexpected error code."

(ert-deftest igc-test-thread-incremental-gc ()
  "Trigger incremental GC on a second thread."
  :tags '(:igc :expensive-test)
  (skip-unless (fboundp 'make-thread))
  (igc-collect)
  (thread-join (make-thread #'igc-test--trigger-incremental-gc)))

(ert-deftest igc-test-w32-select-thread-race ()
  "Process W32 file notifications while another Lisp thread allocates."
  :tags '(:igc :expensive-test)
  (skip-unless (eq system-type 'windows-nt))
  (skip-unless (fboundp 'make-thread))
  (skip-unless (featurep 'w32notify))
  (let* ((dir (make-temp-file "igc-w32-select-" t))
         (file (expand-file-name "notify" dir))
         (stop nil)
         watch thread process)
    (unwind-protect
        (progn
          (setq watch (file-notify-add-watch dir '(change) #'ignore))
          (setq thread
                (make-thread
                 (lambda ()
                   (while (not stop)
                     (dotimes (_ 1000)
                       (string-match "\\(a+\\)\\(b+\\)" "aaabbb")
                       (match-data))
                     (thread-yield)))))
          (setq process
                (start-process
                 "igc-w32-select" nil "cmd.exe" "/d" "/q" "/c"
                 (format "for /l %%i in (1,1,20000) do @echo .>>\"%s\""
                         file)))
          (with-timeout (60 (ert-fail "Test timed out"))
            (while (process-live-p process)
              (accept-process-output process 0.01))
            (setq stop t)
            (thread-join thread)))
      (when (and process (process-live-p process))
        (delete-process process))
      (setq stop t)
      (when (and thread (thread-live-p thread))
        (thread-join thread))
      (when watch
        (file-notify-rm-watch watch))
      (delete-directory dir t))))

(defun igc-tests--binary-search (start end cmp)
  (named-let search ((start start) (end end))
    (let* ((len (- end start))
           (mid (+ start (/ len 2))))
      (cond ((= len 0)
             nil)
            (t
             (cl-ecase (funcall cmp mid)
               (= mid)
               (< (search start mid))
               (> (search (1+ mid) end))))))))

(defun igc-tests--try-vector-size (len)
  (message "testing: %d (0x%x) (logb: %d)" len len (logb len))
  (igc--process-messages)
  (cond ((ignore-errors (length (make-vector len nil)))
         (cond ((ignore-errors (length (make-vector (1+ len) nil)))
                '>)
               (t
                '=)))
        (t '<)))

;; FIXME: this crashes with 32-bit configurations
(ert-deftest igc-tests-find-largest-vector-size ()
  "Find the largest size which we can allocate a vector."
  :tags '(:igc :expensive-test)
  (let ((garbage-collection-messages t))
    (igc-tests--binary-search 0 (1+ most-positive-fixnum)
                              #'igc-tests--try-vector-size)))

;;; igc-tests.el ends here.
