;;; unsafep-tests.el --- tests for unsafep.el  -*- lexical-binding: t; -*-

;; Author: Jonathan Yavner <jyavner@member.fsf.org>

;; Copyright (C) 2002-2025 Free Software Foundation, Inc.

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
(require 'unsafep)

(defvar safe-functions)

;;; These forms are all considered safe
(defconst unsafep-tests--safe
  '(((lambda (x) (* x 2)) 14)
    (apply 'cdr (mapcar (lambda (x) (car x)) y))
    (cond ((= x 4) 5) (t 27))
    (condition-case x (car y) (error (car x)))
    (let (x) (dolist (y '(1 2 3) (1+ y)) (push y x)))
    (let (x) (apply (lambda (x) (* x 2)) 14))
    (let ((x '(2))) (push 1 x) (pop x) (add-to-list 'x 2))
    (let ((x 1) (y 2)) (setq x (+ x y)))
    (let ((x 1)) (let ((y (+ x 3))) (* x y)))
    (let* nil (current-time))
    (let* ((x 1) (y (+ x 3))) (* x y))
    (mapcar (lambda (x &optional y &rest z) (setq y (+ x 2)) (* y 3)) '(1 2 3))
    (mapconcat #'(lambda (var) (propertize var 'face 'bold)) '("1" "2") ", ")
    (setq buffer-display-count 14 mark-active t)
    ;;This is not safe if you insert it into a buffer!
    (propertize "x" 'display '(height (progn (delete-file "x") 1))))
  "List of forms that `unsafep' should decide are safe.")

;;; These forms are considered unsafe
(defconst unsafep-tests--unsafe
  '(( (add-to-list x y)
      . (unquoted x))
    ( (add-to-list y x)
      . (unquoted y))
    ( (add-to-list 'y x)
      . (global-variable y))
    ( (not (delete-file "unsafep.el"))
      . (function delete-file))
    ( (cond (t (aset local-abbrev-table 0 0)))
      . (function aset))
    ( (cond (t (setq unsafep-vars "")))
      . (risky-local-variable unsafep-vars))
    ( (condition-case format-alist 1)
      . (risky-local-variable format-alist))
    ( (condition-case x 1 (error (setq format-alist "")))
      . (risky-local-variable format-alist))
    ( (dolist (x (sort globalvar 'car)) (princ x))
      . (function sort))
    ( (dotimes (x 14) (delete-file "x"))
      . (function delete-file))
    ( (let ((post-command-hook "/tmp/")) 1)
      . (risky-local-variable post-command-hook))
    ( (let ((x (delete-file "x"))) 2)
      . (function delete-file))
    ( (let (x) (add-to-list 'x (delete-file "x")))
      . (function delete-file))
    ( (let (x) (condition-case y (setq x 1 z 2)))
      . (global-variable z))
    ( (let (x) (condition-case z 1 (error (delete-file "x"))))
      . (function delete-file))
    ( (let (x) (mapc (lambda (x) (setcar x 1)) '((1 . 2) (3 . 4))))
      . (function setcar))
    ( (let (y) (push (delete-file "x") y))
      . (function delete-file))
    ( (let* ((x 1)) (setq y 14))
      . (global-variable y))
    ( (mapc 'car (list '(1 . 2) (cons 3 4) (kill-buffer "unsafep.el")))
      . (function kill-buffer))
    ( (mapcar x y)
      . (unquoted x))
    ( (mapcar (lambda (x) (rename-file x "x")) '("unsafep.el"))
      . (function rename-file))
    ( (mapconcat x1 x2 " ")
      . (unquoted x1))
    ( (pop format-alist)
      . (risky-local-variable format-alist))
    ( (push 1 format-alist)
      . (risky-local-variable format-alist))
    ( (setq buffer-display-count (delete-file "x"))
      . (function delete-file))
    ;;These are actually safe (they signal errors)
    ( (apply '(x) '(1 2 3))
      . (function (x)))
    ( (let (((x))) 1)
      . (variable (x)))
    ( (let (1) 2)
      . (variable 1))
    ( (error "Asdf")
      . #'error)
    ( (signal 'error "asdf")
      . #'signal)
    ( (throw 'asdf)
      . #'throw)
    ( (catch 'asdf 17)
      . #'catch)
    ( (play-sound-file "asdf")
      . #'play-sound-file)
    ( (replace-regexp-in-string "a" "b")
      . #'replace-regexp-in-string)
    )
  "A-list of (FORM . REASON)... that `unsafep' should decide are unsafe.")

(ert-deftest test-unsafep/safe ()
  "Check safe forms with safe-functions nil."
  (let (safe-functions)
    (dolist (x unsafep-tests--safe)
      (should-not (unsafep x)))))

(ert-deftest test-unsafep/message ()
  "Check that message is considered unsafe."
  (should (unsafep '(dolist (x y) (message "here: %s" x))))
  (should (unsafep '(dotimes (x 14 (* x 2)) (message "here: %d" x)))))

(ert-deftest test-unsafep/unsafe ()
  "Check unsafe forms with safe-functions nil."
  (let (safe-functions)
    (dolist (x unsafep-tests--unsafe)
      (should (equal (unsafep (car x)) (cdr x))))))

(ert-deftest test-unsafep/safe-functions-t ()
  "safe-functions=t should allow delete-file"
  (let ((safe-functions t))
    (should-not (unsafep '(delete-file "x")))
    (should-not (unsafep-function 'delete-file))))

(ert-deftest test-unsafep/safe-functions-setcar ()
  "safe-functions=(setcar) should allow setcar but not setcdr"
  (let ((safe-functions '(setcar)))
    (should-not (unsafep '(setcar x 1)))
    (should (unsafep '(setcdr x 1)))))

(provide 'unsafep-tests)

;;; unsafep-tests.el ends here
