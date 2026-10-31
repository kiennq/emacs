;;; igc-tests.el --- tests for src/igc.c  -*- lexical-binding: t -*-

;; Copyright (C) 2024-2026 Free Software Foundation, Inc.

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

(declare-function igc--roots "igc.c")
(declare-function igc--set-commit-limit "igc.c")
(declare-function igc--set-pause-time "igc.c")
(declare-function igc-info "igc.c")

(defun igc-tests--commit-limit ()
  (pcase-exhaustive (assoc-string "commit-limit" (igc-info))
    (`("commit-limit" nil ,val nil) val)))

(defun igc-tests--committed ()
  (pcase-exhaustive (assoc-string "committed" (igc-info))
    (`("committed" nil ,val nil) val)))

(ert-deftest igc-tests-set-commit-limit ()
  :tags '(:igc)
  (let ((limit (max (ash 1 30) (igc-tests--committed))))
    (should (equal (igc--set-commit-limit limit) nil))
    (should (equal (igc-tests--commit-limit) limit)))
  (should-error (igc--set-commit-limit -1)
                :type 'args-out-of-range)
  (should-error (igc--set-commit-limit
                 (if (< #x1fffffff most-positive-fixnum)
                     (- (ash 1 64) 1)
                   (- (ash 1 32) 1))
                :type 'args-out-of-range))
  (should (equal (igc--set-commit-limit nil) nil))
  (should (member (igc-tests--commit-limit)
                  '(#xffffffff #xffffffffffffffff))))

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

(ert-deftest igc-test-w32-timer-not-mps-registered ()
  "Keep the W32 timer thread outside the MPS thread ring."
  :tags '(:igc)
  (skip-unless (eq system-type 'windows-nt))
  (skip-unless (fboundp 'igc--roots))
  (skip-unless (fboundp 'profiler-cpu-start))
  (let ((emacs (expand-file-name invocation-name invocation-directory)))
    (skip-unless (file-executable-p emacs))
    (with-temp-buffer
      (let ((status
             (call-process
              emacs nil '(t t) nil
              "-Q" "--batch" "--eval"
              (prin1-to-string
               '(let ((control-stack-count
                       (lambda ()
                         (let ((count 0))
                           (dolist (root (igc--roots) count)
                             (when (equal (car root) "control stack")
                               (setq count (1+ count))))))))
                  (let ((before (funcall control-stack-count))
                        (after 0)
                        (unchanged t))
                    (unwind-protect
                        (progn
                          (profiler-cpu-start
                           (min most-positive-fixnum 10000000000))
                          (dotimes (_ 20)
                            (sleep-for 0.01)
                            (setq after (funcall control-stack-count))
                            (unless (= after before)
                              (setq unchanged nil))))
                      (profiler-cpu-stop))
                    (unless unchanged
                      (princ (format "control-stack roots: %d -> %d\n"
                                     before after)))
                    (kill-emacs (if unchanged 0 1))))))))
        (ert-info ((concat "Process output:\n" (buffer-string)))
          (should (eql status 0)))))))

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

(defun igc-tests--try-vector-size (len alloc-fun)
  (message "testing: %d (0x%x) (logb: %d)" len len (logb len))
  (when (featurep 'mps)
    (igc--process-messages))
  (cond ((ignore-errors (funcall alloc-fun len))
         (cond ((ignore-errors (funcall alloc-fun (1+ len)))
                '>)
               (t '=)))
        (t '<)))

(defun igc-tests--find-largest-vector-size (alloc-fun)
  (let ((garbage-collection-messages t)
        (cmp-fun (lambda (len)
                   (igc-tests--try-vector-size len alloc-fun))))
    (igc-tests--binary-search 0 (1+ most-positive-fixnum) cmp-fun)))

(ert-deftest igc-tests-find-largest-vector-size ()
  "Find the largest size a vector."
  :tags '(:expensive-test)
  (igc-tests--find-largest-vector-size (lambda (len)
                                         (length (make-vector len nil)))))

(ert-deftest igc-tests-find-largest-string-size ()
  "Find the largest size for which we can allocate a string."
  :tags '(:expensive-test)
  (igc-tests--find-largest-vector-size (lambda (len)
                                         (length (make-string len ?a)))))

(ert-deftest igc-tests-find-largest-hash-table-size ()
  "Find the largest size for which we can allocate a hash table."
  :tags '(:expensive-test)
  (igc-tests--find-largest-vector-size
   (lambda (size) (hash-table-size (make-hash-table :size size)))))

(ert-deftest igc-tests-find-largest-bool-vector-size ()
  "Find the largest size for which we can allocate a bool vector."
  :tags '(:expensive-test)
  (igc-tests--find-largest-vector-size
   (lambda (size) (length (make-bool-vector size nil)))))

(ert-deftest igc-tests-collect-undo-list ()
  "Test that adjust-weak-markers entries are removed."
  (skip-unless (fboundp 'make-thread))
  (with-temp-buffer
    (insert "123456789")
    (setq buffer-undo-list nil)
    (insert "0")
    (thread-join (make-thread
                  (lambda ()
                    (goto-char 5)
                    (let ((m (point-marker)))
                      (delete-region 3 7)
                      (should (= m 3))))))
    (should (pcase-exhaustive (list (featurep 'mps) buffer-undo-list)
              (`(t (("3456" . 3)
                    (apply 0 (3 . 7) undo--adjust-weak-markers ((,id . 2)))
                    (10 . 11)))
               (fixnump id))
              (`(nil (("3456" . 3) (,m . -2) (10 . 11)))
               (and (eq (marker-buffer m) (current-buffer))))
              (_ nil)))
    (cond ((featurep 'mps)
           ;; test that we can delete the first element of buffer-undo-list
           (pop buffer-undo-list)
           (igc--collect)
           (igc--process-messages))
          (t
           (garbage-collect)))
    (pcase-exhaustive (list (featurep 'mps) buffer-undo-list)
      (`(t ((10 . 11))))
      (`(nil (("3456" . 3) (10 . 11)))))))

(ert-deftest igc-tests-malformed-undo-list ()
  "Test that malformed undo-list entries don't crash Emacs."
  :tags '(:igc)
  (with-temp-buffer
    (let ((bad-entries
           '((apply 0 (1 . 1) undo--adjust-weak-markers )
             (apply 0 (1 . 1) undo--adjust-weak-markers t)
             (apply 0 (1 . 1) undo--adjust-weak-markers (1 . 2) (3 . 4))
             (apply 0 (1 . 1) undo--adjust-weak-markers ((t . 1) (t . -1)))
             (apply 0 (1 . 1) undo--adjust-weak-markers (t (2 . -1)))
             (apply 0 (1 . 1) . a)
             (apply 0 (1 . 1) undo--adjust-weak-markers . b))))
      (dolist (entry bad-entries)
        (erase-buffer)
        (insert "123456789")
        (setq buffer-undo-list nil)
        (thread-join
         (make-thread
          (lambda ()
            (let ((m (copy-marker 5)))
              (delete-region 3 7)
              (should (= m 3))))))
        (push entry buffer-undo-list)
        (igc--collect)
        (condition-case e
            (igc--process-messages)
          (t (pcase-exhaustive e
               (`(error "Malformed undo-list entry" ,_))
               (`(wrong-type-argument listp ,_)))))))))

(ert-deftest igc-tests-malformed-undo-list-2 ()
  (with-temp-buffer
    (let ((bad-lists '(t (t . 0) 123 [] (nil [])
                         (("x" . 1) . a))))
      (dolist (list bad-lists)
        (erase-buffer)
        (insert "123456789")
        (setq buffer-undo-list nil)
        (thread-join
         (make-thread
          (lambda ()
            (let ((m (copy-marker 5)))
              (delete-region 3 7)))))
        (setq buffer-undo-list list)
        (igc--collect)
        (igc--process-messages)))))

;;; igc-tests.el ends here.
