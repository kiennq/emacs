;;; elec-pair.el --- Automatically insert matching delimiters  -*- lexical-binding:t -*-

;; Copyright (C) 2013-2025 Free Software Foundation, Inc.

;; Author: João Távora <joaotavora@gmail.com>

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

;;  This library provides a way to easily insert pairs of matching
;;  delimiters (parentheses, braces, brackets, quotes, etc.) and
;;  optionally preserve or override the balance of delimiters.  It is
;;  documented in the Emacs user manual node "(emacs) Matching".

;;; Code:

(require 'electric)
(eval-when-compile (require 'cl-lib))

;;; Electric pairing.

(defcustom electric-pair-pairs
  `((?\" . ?\")
    (,(nth 0 electric-quote-chars) . ,(nth 1 electric-quote-chars))
    (,(nth 2 electric-quote-chars) . ,(nth 3 electric-quote-chars)))
  "Alist of pairs that should be used regardless of major mode.

Pairs of delimiters in this list are a fallback in case they have
no syntax relevant to `electric-pair-mode' in the mode's syntax
table.

Each list element should be in one of these forms:
 (CHAR . CHAR)
Where CHAR is character to be used as pair.

 (STRING STRING SPC)
Where STRING is a string to be used as pair and SPC a non-nil value
which specifies to insert an extra space after first STRING.

 (STRING . STRING)
This is similar to (STRING STRING SPC) form, except that SPC (space) is
ignored and will not be inserted.

In both string pairs forms, the first string pair must be a regular
expression.

In comparation to character pairs, string pairs does not support
inserting pairs in regions and can not be deleted with
`electric-pair-delete-pair', thus string pairs should be used only for
multi-character pairs.

See also the variable `electric-pair-text-pairs'."
  :version "24.1"
  :group 'electricity
  :type '(repeat
          (choice (cons :tag "Characters" character character)
                  (cons :tag "Strings" string string)
                  (list :tag "Strings, plus insert SPC after first string"
                        string string boolean))))

(defcustom electric-pair-text-pairs
  `((?\" . ?\")
    (,(nth 0 electric-quote-chars) . ,(nth 1 electric-quote-chars))
    (,(nth 2 electric-quote-chars) . ,(nth 3 electric-quote-chars)))
  "Alist of pairs that should always be used in comments and strings.

Pairs of delimiters in this list are a fallback in case they have
no syntax relevant to `electric-pair-mode' in the syntax table
defined in `electric-pair-text-syntax-table'.

Each list element should be in one of these forms:
 (CHAR . CHAR)
Where CHAR is character to be used as pair.

 (STRING STRING SPC)
Where STRING is a string to be used as pair and SPC a non-nil value
which specifies to insert an extra space after first STRING.

 (STRING . STRING)
This is similar to (STRING STRING SPC) form, except that SPC (space) is
ignored and will not be inserted.

In both string pairs forms, the first string pair must be a regular
expression.

In comparation to character pairs, string pairs does not support
inserting pairs in regions and can not be deleted with
`electric-pair-delete-pair', thus string pairs should be used only for
multi-character pairs.

See also the variable `electric-pair-pairs'."
  :version "24.4"
  :group 'electricity
  :type '(repeat
          (choice (cons :tag "Characters" character character)
                  (cons :tag "Strings" string string)
                  (list :tag "Strings, plus insert SPC after first string"
                        string string boolean))))

(defcustom electric-pair-skip-self #'electric-pair-default-skip-self
  "If non-nil, skip char instead of inserting a second closing paren.

When inserting a closing delimiter right before the same character, just
skip that character instead, so that, for example, consecutively
typing `(' and `)' results in \"()\" rather than \"())\".

This can be convenient for people who find it easier to type `)' than
\\[forward-char].

Can also be a function of one argument (the closing delimiter just
inserted), in which case that function's return value is considered
instead."
  :version "24.1"
  :group 'electricity
  :type '(choice
          (const :tag "Never skip" nil)
          (const :tag "Help balance" electric-pair-default-skip-self)
          (const :tag "Always skip" t)
          function))

(defcustom electric-pair-inhibit-predicate
  #'electric-pair-default-inhibit
  "Predicate to prevent insertion of a matching pair.

The function is called with a single char (the opening delimiter just
inserted).  If it returns non-nil, then `electric-pair-mode' will not
insert a matching closing delimiter."
  :version "24.4"
  :group 'electricity
  :type '(choice
          (const :tag "Conservative" electric-pair-conservative-inhibit)
          (const :tag "Help balance" electric-pair-default-inhibit)
          (const :tag "Always pair" ignore)
          function))

(defcustom electric-pair-preserve-balance t
  "Whether to keep matching delimiters balanced.
When non-nil, typing a delimiter inserts only this character if there is
a unpaired matching delimiter later (if the latter is a closing
delimiter) or earlier (if the latter is a opening delimiter) in the
buffer.  When nil, inserting a delimiter disregards unpaired matching
delimiters.

Whether this variable takes effect depends on the variables
`electric-pair-inhibit-predicate' and `electric-pair-skip-self', which
check the value of this variable before delegating to other predicates
responsible for making decisions on whether to pair/skip some characters
based on the actual state of the buffer's delimiters.  In addition, this
variable has no effect if there is an active region."
  :version "24.4"
  :group 'electricity
  :type 'boolean)

(defcustom electric-pair-delete-adjacent-pairs t
  "Whether to automatically delete a matching delimiter.
If non-nil, then when an opening delimiter immediately precedes a
matching closing delimiter and point is between them, typing DEL (the
backspace key) deletes both delimiters.  If nil, only the opening
delimiter is deleted.

The value of this variable can also be a function of no arguments, in
which case that function's return value is considered instead."
  :version "24.4"
  :group 'electricity
  :type '(choice
          (const :tag "Yes" t)
          (const :tag "No" nil)
          function))

(defcustom electric-pair-open-newline-between-pairs t
  "Whether to insert an extra newline between matching delimiters.
If non-nil, then when an opening delimiter immediately precedes a
matching closing delimiter and point is between them, typing a newline
automatically inserts an extra newline after point.  If nil, just one
newline is inserted before point.

The value of this variable can also be a function of no arguments, in
which case that function's return value is considered instead."
  :version "24.4"
  :group 'electricity
  :type '(choice
          (const :tag "Yes" t)
          (const :tag "No" nil)
          function))

(defcustom electric-pair-skip-whitespace t
  "Whether typing a closing delimiter moves point over whitespace.
If non-nil and point is separated from a closing delimiter only by
whitespace, then typing a closing delimiter of the same type does not
insert that character but instead moves point to immediately after the
already present closing delimiter.  If the value of this variable is set
tothe symbol `chomp', then the whitespace moved over is deleted.  If the
value is nil, typing a closing delimiter simply inserts it at point.

The specific kind of whitespace skipped is given by the variable
`electric-pair-skip-whitespace-chars'.

The value of this variable can also be a function of no arguments, in
which case that function's return value is considered instead."
  :version "24.4"
  :group 'electricity
  :type '(choice
          (const :tag "Yes, jump over whitespace" t)
          (const :tag "Yes, and delete whitespace" chomp)
          (const :tag "No, no whitespace skipping" nil)
          function))

(defcustom electric-pair-skip-whitespace-chars (list ?\t ?\s ?\n)
  "Whitespace characters considered by `electric-pair-skip-whitespace'."
  :version "24.4"
  :group 'electricity
  :type '(choice (set (const :tag "Space" ?\s)
                      (const :tag "Tab" ?\t)
                      (const :tag "Newline" ?\n))
                 (repeat (character :value " "))))

(defvar-local electric-pair-skip-whitespace-function
  #'electric-pair--skip-whitespace
  "Function to use to move point forward over whitespace.
Before attempting a skip, if `electric-pair-skip-whitespace' is
non-nil, this function is called.  It moves point to a new buffer
position, presumably skipping only whitespace in between.")

(defun electric-pair-analyze-conversion (string)
  "Delete delimiters enclosing the STRING deleted by an input method.
If the last character of STRING is an electric pair character,
and the character after point is too, then delete that other
character.  Called by `analyze-text-conversion'."
  (let* ((prev (aref string (1- (length string))))
         (next (char-after))
         (syntax-info (electric-pair-syntax-info prev))
         (syntax (car syntax-info))
         (pair (cadr syntax-info)))
    (when (and next pair (memq syntax '(?\( ?\" ?\$))
               (eq pair next))
      (delete-char 1))))

(defun electric-pair--skip-whitespace ()
  "Move point forward over whitespace.
But do not move point if doing so crosses comment or string boundaries."
  (let ((saved (point))
        (string-or-comment (nth 8 (syntax-ppss))))
    (skip-chars-forward (apply #'string electric-pair-skip-whitespace-chars))
    (unless (eq string-or-comment (nth 8 (syntax-ppss)))
      (goto-char saved))))

(defvar electric-pair-text-syntax-table prog-mode-syntax-table
  "Syntax table used when pairing inside comments and strings.

`electric-pair-mode' considers this syntax table only when point is
within text marked as a comment or enclosed within quotes.  If lookup
fails here, `electric-pair-text-pairs' will be considered.")

(defun electric-pair-conservative-inhibit (char)
  (or
   ;; I find it more often preferable not to pair when the
   ;; same char is next.
   (eq char (char-after))
   ;; Don't pair up when we insert the second of "" or of ((.
   (and (eq char (char-before))
	(eq char (char-before (1- (point)))))
   ;; I also find it often preferable not to pair next to a word.
   (eq (char-syntax (following-char)) ?w)))

(defmacro electric-pair--with-syntax (string-or-comment &rest body)
  "Run BODY with appropriate syntax table active.
STRING-OR-COMMENT is the start position of the string/comment
in which we are, if applicable.
Uses the `text-mode' syntax table if within a string or a comment."
  (declare (debug t) (indent 1))
  `(electric-pair--with-syntax-1 ,string-or-comment (lambda () ,@body)))

(defun electric-pair--with-syntax-1 (string-or-comment body-fun)
  (if (not string-or-comment)
      (funcall body-fun)
    ;; Here we assume that the `syntax-ppss' cache has already been filled
    ;; past `string-or-comment' with data corresponding to the "normal" syntax
    ;; (this should be the case because STRING-OR-COMMENT was returned
    ;; in the `nth 8' of `syntax-ppss').
    ;; Maybe we should narrow-to-region so that `syntax-ppss' uses the narrow
    ;; cache?
    (syntax-ppss-flush-cache string-or-comment)
    (let ((syntax-propertize-function nil))
       (unwind-protect
           (with-syntax-table electric-pair-text-syntax-table
             (funcall body-fun))
         (syntax-ppss-flush-cache string-or-comment)))))

(defun electric-pair-syntax-info (command-event)
  "Calculate a list (SYNTAX PAIR UNCONDITIONAL STRING-OR-COMMENT-START).

SYNTAX is COMMAND-EVENT's syntax character.  PAIR is COMMAND-EVENT's
pair.  UNCONDITIONAL indicates that the variables `electric-pair-pairs'
or `electric-pair-text-pairs' were used to look up syntax.
STRING-OR-COMMENT-START indicates that point is inside a comment or
string."
  (let* ((pre-string-or-comment (or (bobp)
                                    (nth 8 (save-excursion
                                             (syntax-ppss (1- (point)))))))
         (post-string-or-comment (nth 8 (syntax-ppss (point))))
         (string-or-comment (and post-string-or-comment
                                 pre-string-or-comment))
         (table-syntax-and-pair
          (electric-pair--with-syntax string-or-comment
            (list (char-syntax command-event)
                  (or (matching-paren command-event)
                      command-event))))
         (fallback (if string-or-comment
                       (append electric-pair-text-pairs
                               electric-pair-pairs)
                     electric-pair-pairs))
         (direct (assq command-event fallback))
         (reverse (rassq command-event fallback)))
    (cond
     ((cl-loop
       for pairs in fallback
       if (and
	   (stringp (car pairs))
	   (looking-back (car pairs) (pos-bol)))
         return (list
                 'str
                 ;; Get pair ender
                 (if (proper-list-p pairs)
                     (nth 1 pairs)
                   (cdr pairs))
                 nil
                 ;; Check if pairs have to insert a space after
                 ;; first pair was inserted.
                 (if (proper-list-p pairs)
                     (nth 2 pairs)))))
     ((memq (car table-syntax-and-pair)
            '(?\" ?\( ?\) ?\$))
      (append table-syntax-and-pair (list nil string-or-comment)))
     (direct (if (eq (car direct) (cdr direct))
                 (list ?\" command-event t string-or-comment)
               (list ?\( (cdr direct) t string-or-comment)))
     (reverse (list ?\) (car reverse) t string-or-comment)))))

(defun electric-pair--insert (char times)
  (let ((last-command-event char)
	(blink-matching-paren nil)
	(electric-pair-mode nil)
        ;; When adding a closing delimiter, a job this function is
        ;; frequently used for, we don't want to munch any extra
        ;; newlines above us.  That would be the default behavior of
        ;; `electric-layout-mode', which potentially kicked in before us
        ;; to add these newlines, and is probably about to kick in again
        ;; after we add the closer.
        (electric-layout-allow-duplicate-newlines t))
    (self-insert-command times)))

(defun electric-pair--syntax-ppss (&optional pos where)
  "Like `syntax-ppss', but maybe fall back to `parse-partial-sexp'.

WHERE is a list defaulting to \\='(string comment) and indicates
when to fall back to `parse-partial-sexp'."
  (let* ((pos (or pos (point)))
         (where (or where '(string comment)))
         (quick-ppss (syntax-ppss pos))
         (in-string (and (nth 3 quick-ppss) (memq 'string where)))
         (in-comment (and (nth 4 quick-ppss) (memq 'comment where)))
         (s-or-c-start (cond (in-string
                              (1+ (nth 8 quick-ppss)))
                             (in-comment
                              (goto-char (nth 8 quick-ppss))
                              (forward-comment (- (point-max)))
                              (skip-syntax-forward " >!")
                              (point)))))
    (if s-or-c-start
        (electric-pair--with-syntax s-or-c-start
          (parse-partial-sexp s-or-c-start pos))
      ;; HACK! cc-mode apparently has some `syntax-ppss' bugs
      (if (memq major-mode '(c-mode c++ mode))
          (parse-partial-sexp (point-min) pos)
        quick-ppss))))

;; Balancing means controlling pairing and skipping of delimiters
;; so that, if possible, the buffer ends up at least as balanced as
;; before, if not more.  The algorithm is slightly complex because
;; some situations like "()))" need pairing to occur at the end but
;; not at the beginning.  Balancing should also happen independently
;; for different types of delimiter, so that having your {}'s
;; unbalanced doesn't keep `electric-pair-mode' from balancing your
;; ()'s and your []'s.
(defun electric-pair--balance-info (direction string-or-comment)
  "Examine lists forward or backward according to DIRECTION's sign.

STRING-OR-COMMENT is the position of the start of the comment/string
in which we are, if applicable.

Return a cons of two descriptions (MATCHED-P . PAIR) for the
innermost and outermost lists that enclose point.  The outermost
list enclosing point is either the first top-level or first
mismatched list found by listing up.

If the outermost list is matched, don't rely on its PAIR.
If point is not enclosed by any lists, return ((t) . (t))."
  (let* (innermost
         outermost
         (at-top-level-or-equivalent-fn
          ;; Called when `scan-sexps' ran perfectly, when it found
          ;; a parenthesis pointing in the direction of travel.
          ;; Also when travel started inside a comment and exited it.
          (lambda ()
            (setq outermost (list t))
            (unless innermost
              (setq innermost (list t)))))
         (ended-prematurely-fn
          ;; Called when `scan-sexps' crashed against a parenthesis
          ;; pointing opposite the direction of travel.  After
          ;; traversing that character, the idea is to travel one sexp
          ;; in the opposite direction looking for a matching
          ;; delimiter.
          (lambda ()
            (let* ((pos (point))
                   (matched
                    (save-excursion
                      (cond ((< direction 0)
                             (condition-case nil
                                 (eq (char-after pos)
                                     (electric-pair--with-syntax
                                         string-or-comment
                                       (matching-paren
                                        (char-before
                                         (scan-sexps (point) 1)))))
                               (scan-error nil)))
                            (t
                             ;; In this case, no need to use
                             ;; `scan-sexps', we can use some
                             ;; `electric-pair--syntax-ppss' in this
                             ;; case (which uses the quicker
                             ;; `syntax-ppss' in some cases)
                             (let* ((ppss (electric-pair--syntax-ppss
                                           (1- (point))))
                                    (start (car (last (nth 9 ppss))))
                                    (opener (char-after start)))
                               (and start
                                    (eq (char-before pos)
                                        (or (electric-pair--with-syntax
                                                string-or-comment
                                              (matching-paren opener))
                                            opener))))))))
                   (actual-pair (if (> direction 0)
                                    (char-before (point))
                                  (char-after (point)))))
              (unless innermost
                (setq innermost (cons matched actual-pair)))
              (unless matched
                (setq outermost (cons matched actual-pair)))))))
    (save-excursion
      (while (not outermost)
        (condition-case err
            (electric-pair--with-syntax string-or-comment
              (scan-sexps (point) (if (> direction 0)
                                      (point-max)
                                    (- (point-max))))
              (funcall at-top-level-or-equivalent-fn))
          (scan-error
           (cond ((or
                   ;; Some error happened and it is not of the "ended
                   ;; prematurely" kind...
                   (not (string-match "ends prematurely" (nth 1 err)))
                   ;; ... or we were in a comment and just came out of
                   ;; it.
                   (and string-or-comment
                        (not (nth 8 (syntax-ppss)))))
                  (funcall at-top-level-or-equivalent-fn))
                 (t
                  ;; Exit the sexp.
                  (goto-char (nth 3 err))
                  (funcall ended-prematurely-fn)))))))
    (cons innermost outermost)))

(defvar electric-pair-string-bound-function 'point-max
  "Next buffer position where strings are syntactically unexpected.
Value is a function called with no arguments and returning a
buffer position.  Major modes should set this variable
buffer-locally if they experience slowness with
`electric-pair-mode' when pairing quotes.")

(defun electric-pair--unbalanced-strings-p (char)
  "Return non-nil if there are unbalanced strings started by CHAR."
  (let* ((selector-ppss (syntax-ppss))
         (relevant-ppss (save-excursion
                          (if (nth 4 selector-ppss) ; comment
                              (electric-pair--syntax-ppss
                               (progn
                                 (goto-char (nth 8 selector-ppss))
                                 (forward-comment (point-max))
                                 (skip-syntax-backward " >!")
                                 (point)))
                            (syntax-ppss
                             (funcall electric-pair-string-bound-function)))))
         (string-delim (nth 3 relevant-ppss)))
    (or (eq t string-delim)
        (eq char string-delim))))

(defun electric-pair--inside-string-p (char)
  "Return non-nil if point is inside a string started by CHAR.

A comments text is parsed with `electric-pair-text-syntax-table'.
Also consider strings within comments, but not strings within
strings."
  ;; FIXME: could also consider strings within strings by examining
  ;; delimiters.
  (let ((ppss (electric-pair--syntax-ppss (point) '(comment))))
    (memq (nth 3 ppss) (list t char))))

(defmacro electric-pair--save-literal-point-excursion (&rest body)
  ;; FIXME: need this instead of `save-excursion' when functions in
  ;; BODY, such as `electric-pair-inhibit-if-helps-balance' and
  ;; `electric-pair-skip-if-helps-balance' modify and restore the
  ;; buffer in a way that modifies the marker used by save-excursion.
  (let ((point (make-symbol "point")))
    `(let ((,point (point)))
       (unwind-protect (progn ,@body) (goto-char ,point)))))

(defun electric-pair-inhibit-if-helps-balance (char)
  "Return non-nil if auto-pairing of CHAR unbalances delimiters.

Works by first removing the character from the buffer, then doing
some list calculations, finally restoring the situation as if nothing
happened."
  (pcase (electric-pair-syntax-info char)
    (`(,syntax ,pair ,_ ,s-or-c)
     (catch 'done
       ;; FIXME: modify+undo is *very* tricky business.  We used to
       ;; use `delete-char' followed by `insert', but this changed the
       ;; position some markers.  The real fix would be to compute the
       ;; result without having to modify the buffer at all.
       (atomic-change-group
         ;; Don't use `delete-char'; that may modify the head of the
         ;; undo list.
         (delete-region (- (point) (prefix-numeric-value current-prefix-arg))
                        (point))
         (throw
          'done
          (cond ((eq ?\( syntax)
                 (let* ((pair-data
                         (electric-pair--balance-info 1 s-or-c))
                        (outermost (cdr pair-data)))
                   (cond ((car outermost)
                          nil)
                         (t
                          (eq (cdr outermost) pair)))))
                ((eq syntax ?\")
                 (electric-pair--unbalanced-strings-p char)))))))))

(defun electric-pair-skip-if-helps-balance (char)
  "Return non-nil if skipping CHAR preserves balance of delimiters.
Works by first removing the character from the buffer, then doing
some list calculations, finally restoring the situation as if nothing
happened."
  (let ((num (prefix-numeric-value current-prefix-arg)))
    (pcase (electric-pair-syntax-info char)
      (`(,syntax ,pair ,_ ,s-or-c)
       (unwind-protect
           (progn
             (delete-char (- num))
             (cond ((eq syntax ?\))
                    (let* ((pair-data
                            (electric-pair--balance-info
                             (- num) s-or-c))
                           (innermost (car pair-data))
                           (outermost (cdr pair-data)))
                      (and
                       (cond ((car outermost)
                              (car innermost))
                             ((car innermost)
                              (not (eq (cdr outermost) pair)))))))
                   ((eq syntax ?\")
                    (electric-pair--inside-string-p char))))
         (insert (make-string num char)))))))

(defun electric-pair-default-skip-self (char)
  (if electric-pair-preserve-balance
      (electric-pair-skip-if-helps-balance char)
    t))

(defun electric-pair-default-inhibit (char)
  (if electric-pair-preserve-balance
      (electric-pair-inhibit-if-helps-balance char)
    (electric-pair-conservative-inhibit char)))

(defun electric-pair-post-self-insert-function ()
  "Do main work for `electric-pair-mode'.
This function is added to `post-self-insert-hook' when
`electric-pair-mode' is enabled.

If the newly inserted character C has delimiter syntax, this
function may decide to insert additional paired delimiters, or
skip the insertion of the new character altogether by jumping
over an existing identical character, or do nothing.

The decision is taken by order of preference:

* According to `use-region-p'.  If this returns non-nil this
  function will unconditionally \"wrap\" the region in the
  corresponding delimiter for C;

* According to C alone, by looking C up in the tables
  `electric-pair-pairs' or `electric-pair-text-pairs' (which
  see);

* According to C's syntax and the syntactic state of the buffer
  (both as defined by the major mode's syntax table).  This is
  done by looking up the variables
 `electric-pair-inhibit-predicate', `electric-pair-skip-self'
  and `electric-pair-skip-whitespace' (which see)."
  (let* ((pos (and electric-pair-mode (electric--after-char-pos)))
         (num (when pos (prefix-numeric-value current-prefix-arg)))
         (beg (when num (- pos num)))
         (skip-whitespace-info))
    (pcase (electric-pair-syntax-info last-command-event)
      (`(,syntax ,pair ,unconditional ,space)
       (cond
        ((null pos) nil)
        ((zerop num) nil)
        ;; Wrap a pair around the active region.
        ;;
        ((and (memq syntax '(?\( ?\) ?\" ?\$)) (use-region-p))
         ;; FIXME: To do this right, we'd need a post-self-insert-function
         ;; so we could add-function around it and insert the closer after
         ;; all the rest of the hook has run.
         (if (or (eq syntax ?\")
                 (and (eq syntax ?\))
                      (>= (point) (mark)))
                 (and (not (eq syntax ?\)))
                      (>= (mark) (point))))
             (save-excursion
               (goto-char (mark))
               (electric-pair--insert pair num))
           (delete-region beg pos)
           (electric-pair--insert pair num)
           (goto-char (mark))
           (electric-pair--insert last-command-event num)))
        ;; Backslash-escaped: no pairing, no skipping.
        ((save-excursion
           (goto-char beg)
           (not (evenp (skip-syntax-backward "\\"))))
         (let ((current-prefix-arg (1- num)))
           (electric-pair-post-self-insert-function)))
        ;; Skip self.
        ((and (memq syntax '(?\) ?\" ?\$))
              (and (or unconditional
                       (if (functionp electric-pair-skip-self)
                           (electric-pair--save-literal-point-excursion
                             (goto-char pos)
                             (funcall electric-pair-skip-self
                                      last-command-event))
                         electric-pair-skip-self))
                   (save-excursion
                     (when (and
                            (not (and unconditional (eq syntax ?\")))
                            (setq skip-whitespace-info
                                  (if (and
                                       (not
                                        (eq electric-pair-skip-whitespace
                                            'chomp))
                                       (functionp electric-pair-skip-whitespace))
                                          (funcall electric-pair-skip-whitespace)
                                        electric-pair-skip-whitespace)))
                       (funcall electric-pair-skip-whitespace-function))
                     (eq (char-after) last-command-event))))
         ;; This is too late: rather than insert&delete we'd want to only
         ;; skip (or insert in overwrite mode).  The difference is in what
         ;; goes in the undo-log and in the intermediate state which might
         ;; be visible to other post-self-insert-hook.  We'll just have to
         ;; live with it for now.
         (when skip-whitespace-info
           (funcall electric-pair-skip-whitespace-function))
         (delete-region beg (if (eq skip-whitespace-info 'chomp)
                                (point)
                              pos))
         (forward-char num))
        ;; Insert matching pair.
        ;; String pairs
        ((and (eq syntax 'str) (not overwrite-mode))
         (if space (insert " "))
         (save-excursion
           (insert pair)))
        ;; Char pairs
        ((and (memq syntax '(?\( ?\" ?\$))
              (not overwrite-mode)
              (or unconditional
                  (not (electric-pair--save-literal-point-excursion
                         (goto-char pos)
                         (funcall electric-pair-inhibit-predicate
                                  last-command-event)))))
         (save-excursion (electric-pair--insert pair num))))))))

(defun electric-pair-open-newline-between-pairs-psif ()
  "Honor `electric-pair-open-newline-between-pairs'.
This function is added to `post-self-insert-hook' when
`electric-pair-mode' is enabled."
  (when (and (if (functionp electric-pair-open-newline-between-pairs)
                 (funcall electric-pair-open-newline-between-pairs)
               electric-pair-open-newline-between-pairs)
             (eq last-command-event ?\n)
             (< (1+ (point-min)) (point) (point-max))
             (eq (save-excursion
                   (skip-chars-backward "\t\s")
                   (char-before (- (point)
                                   (prefix-numeric-value current-prefix-arg))))
                 (matching-paren (char-after))))
    (save-excursion (newline 1 t))))

(defun electric-pair-will-use-region ()
  (and (use-region-p)
       (memq (car (electric-pair-syntax-info last-command-event))
             '(?\( ?\) ?\" ?\$))))

(defun electric-pair-delete-pair (arg &optional killp)
  "When between adjacent paired delimiters, delete both of them.
ARG and KILLP are passed directly to
`backward-delete-char-untabify', which see."
  (interactive "*p\nP")
  (delete-char arg)
  (backward-delete-char-untabify arg killp))

(defvar electric-pair-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\177"
      `(menu-item
        "" electric-pair-delete-pair
        :filter
        ,(lambda (cmd)
           (let* ((prev (char-before))
                  (next (char-after))
                  (syntax-info (and prev
                                    (electric-pair-syntax-info prev)))
                  (syntax (car syntax-info))
                  (pair (cadr syntax-info)))
             (and next pair
                  (memq syntax '(?\( ?\" ?\$))
                  (eq pair next)
                  (if (functionp electric-pair-delete-adjacent-pairs)
                      (funcall electric-pair-delete-adjacent-pairs)
                    electric-pair-delete-adjacent-pairs)
                  cmd)))))
    map)
  "Keymap used by `electric-pair-mode'.")

;;;###autoload
(define-minor-mode electric-pair-mode
  "Toggle automatic pairing of delimiters (Electric Pair mode).

Electric Pair mode is a global minor mode.  When enabled, typing an
opening delimiter (parenthesis, bracket, etc.) automatically inserts the
corresponding closing delimiter.  If the region is active, the
delimiters are inserted around the region instead.

To toggle the mode only in the current buffer, use
`electric-pair-local-mode'."
  :global t :group 'electricity
  (if electric-pair-mode
      (progn
	(add-hook 'post-self-insert-hook
		  #'electric-pair-post-self-insert-function
                  ;; Prioritize this to kick in after
                  ;; `electric-layout-post-self-insert-function': that
                  ;; considerably simplifies interoperation when
                  ;; `electric-pair-mode', `electric-layout-mode' and
                  ;; `electric-indent-mode' are used together.
                  ;; Use `vc-region-history' on these lines for more info.
                  50)
        (add-hook 'post-self-insert-hook
		  #'electric-pair-open-newline-between-pairs-psif
                  50)
	(add-hook 'self-insert-uses-region-functions
		  #'electric-pair-will-use-region))
    (remove-hook 'post-self-insert-hook
                 #'electric-pair-post-self-insert-function)
    (remove-hook 'post-self-insert-hook
                 #'electric-pair-open-newline-between-pairs-psif)
    (remove-hook 'self-insert-uses-region-functions
                 #'electric-pair-will-use-region)))

;;;###autoload
(define-minor-mode electric-pair-local-mode
  "Toggle `electric-pair-mode' only in this buffer."
  :variable ( electric-pair-mode .
              (lambda (val) (setq-local electric-pair-mode val)))
  (cond
   ((eq electric-pair-mode (default-value 'electric-pair-mode))
    (kill-local-variable 'electric-pair-mode))
   ((not (default-value 'electric-pair-mode))
    ;; Locally enabled, but globally disabled.
    (electric-pair-mode 1)		  ; Setup the hooks.
    (setq-default electric-pair-mode nil) ; But keep it globally disabled.
    )))

(provide 'elec-pair)

;;; elec-pair.el ends here
