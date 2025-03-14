;;; find-dired.el --- run a `find' command and dired the output  -*- lexical-binding: t -*-

;; Copyright (C) 1992-2025 Free Software Foundation, Inc.

;; Author: Roland McGrath <roland@gnu.org>,
;;	   Sebastian Kremer <sk@thp.uni-koeln.de>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: unix

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

;;; Code:

(require 'dired)

(defgroup find-dired nil
  "Run a `find' command and Dired the output."
  :group 'dired
  :prefix "find-")

;; FIXME this option does not really belong in this file, it's more general.
;; Eg cf some tests in grep.el.
(defcustom find-exec-terminator
  (if (eq 0
	  (ignore-errors
	    (process-file find-program nil nil nil
			  null-device "-exec" "echo" "{}" "+")))
      "+"
    (shell-quote-argument ";"))
  "String that terminates \"find -exec COMMAND {} \".
The value should include any needed quoting for the shell.
Common values are \"+\" and \"\\\\;\", with the former more efficient
than the latter."
  :version "24.1"
  :group 'find-dired
  :type 'string)

(defvar find-gnu-find-p
  (eq 0 (ignore-errors
          (process-file find-program nil nil nil null-device "--version")))
  "Non-nil if `find-program' is a GNU Find, nil otherwise.")

(defvar find-ls-option-default-ls
  (cons "-ls" (if find-gnu-find-p "-dilsb" "-dgils")))

(defvar find-ls-option-default-exec
  (cons (format "-exec ls -ld {} %s" find-exec-terminator) "-ld"))

(defvar find-ls-option-default-xargs
  (cons "-print0 | sort -z | xargs -0 -e ls -ld" "-ld"))

;; find's -ls corresponds to these switches.
;; Note -b, at least GNU find quotes spaces etc. in filenames
(defcustom find-ls-option
  (if (eq 0
	  (ignore-errors
	    (process-file find-program nil nil nil null-device "-ls")))
      find-ls-option-default-ls
    find-ls-option-default-exec)
  "A pair of options to produce and parse an `ls -l'-type list from `find'.
This is a cons of two strings (FIND-OPTION . LS-SWITCHES).
FIND-OPTION is the option (or options) passed to `find' to produce
a file listing in the desired format.  LS-SWITCHES is a set of
`ls' switches that tell Dired how to parse the output of `find'.

The two options must be set to compatible values.
For example, to use human-readable file sizes with GNU ls:
   (\"-exec ls -ldh {} +\" . \"-ldh\")

To use GNU find's inbuilt \"-ls\" option to list files:
   (\"-ls\" . \"-dilsb\")
since GNU find's output has the same format as using GNU ls with
the options \"-dilsb\".

While the option `find -ls' often produces unsorted output, the option
`find -exec ls -ld' maintains the sorting order only on short output,
whereas `find -print | sort | xargs' produces sorted output even
on a large number of files."
  :version "27.1"            ; add choice of predefined set of options
  :type `(choice
          (cons :tag "find -ls"
                (string ,(car find-ls-option-default-ls))
                (string ,(cdr find-ls-option-default-ls)))
          (cons :tag "find -exec ls -ld"
                (string ,(car find-ls-option-default-exec))
                (string ,(cdr find-ls-option-default-exec)))
          (cons :tag "find -print | sort | xargs"
                (string ,(car find-ls-option-default-xargs))
                (string ,(cdr find-ls-option-default-xargs)))
          (cons :tag "Other values"
                (string :tag "Find Option")
                (string :tag "Ls Switches")))
  :group 'find-dired)

(defcustom find-ls-subdir-switches
  (if (string-match "-[a-z]*b" (cdr find-ls-option))
      "-alb"
    "-al")
  "`ls' switches for inserting subdirectories in `*Find*' buffers.
This should contain the \"-l\" switch.
Use the \"-F\" or \"-b\" switches if and only if you also use
them for `find-ls-option'."
  :version "24.1"			; add -b test
  :type 'string
  :group 'find-dired)

(defcustom find-grep-options
  (if (or (and (eq system-type 'berkeley-unix)
               (not (string-match "openbsd" system-configuration)))
	  (string-match "solaris2" system-configuration))
      "-s" "-q")
  "Option to grep to be as silent as possible.
On Berkeley systems, this is `-s'; on Posix, and with GNU grep, `-q' does it.
On other systems, the closest you can come is to use `-l'."
  :type 'string
  :group 'find-dired)

;; This used to be autoloaded (see bug#4387).
(defcustom find-name-arg
  (if read-file-name-completion-ignore-case
      "-iname"
    "-name")
  "Argument used to specify file name pattern.
If `read-file-name-completion-ignore-case' is non-nil, -iname is used so that
find also ignores case.  Otherwise, -name is used."
  :type 'string
  :group 'find-dired
  :version "22.2")

(defcustom find-dired-refine-function #'find-dired-sort-by-filename
  "If non-nil, a function for refining the *Find* buffer of `find-dired'.
This function takes no arguments.  The *Find* buffer is narrowed to the
output of `find' (one file per line) when this function is called."
  :version "27.1"
  :group 'find-dired
  :type '(choice (const :tag "Sort file names lexicographically"
                        find-dired-sort-by-filename)
                 (function :tag "Refining function")
                 (const :tag "No refining" nil)))

(defvar find-args nil
  "Last arguments given to `find' by \\[find-dired].")

;; History of find-args values entered in the minibuffer.
(defvar find-args-history nil)

(defvar find-command-history nil
  "History of commands passed interactively to `find-dired-with-command'.")

(defvar dired-sort-inhibit)

;;;###autoload
(defun find-dired (dir args)
  "Run `find' and go into Dired mode on a buffer of the output.
The command run (after changing into DIR) is essentially

    find . \\( ARGS \\) -ls

except that the car of the variable `find-ls-option' specifies what to
use in place of \"-ls\" as the final argument.

If your `find' program is not a GNU Find, the columns in the produced
Dired display might fail to align.  We recommend to install GNU Find in
those cases (you may need to customize the value of `find-program' if
you do so), which attempts to align the columns.

Collect output in the \"*Find*\" buffer.  To kill the job before
it finishes, type \\[kill-find].

For more information on how to write valid find expressions for
ARGS, see Info node `(find) Finding Files'.  If you are not
using GNU findutils (on macOS and *BSD systems), see instead the
man page for \"find\"."
  (interactive (list (read-directory-name "Run find in directory: " nil "" t)
		     (read-string "Run find (with args): " find-args
				  (if find-args
                                      '(find-args-history . 1)
                                    'find-args-history))))
  (setq find-args args                ; save for next interactive call
	args (concat find-program " . "
		     (if (string= args "")
			 ""
		       (concat
			(shell-quote-argument "(")
			" " args " "
			(shell-quote-argument ")")
			" "))
		     (find-dired--escaped-ls-option)))
  (find-dired-with-command dir args))

;;;###autoload
(defun find-dired-with-command (dir command)
  "Run `find' and go into Dired mode on a buffer of the output.
The user-supplied COMMAND is run after changing into DIR and should look like

    find . GLOBALARGS \\( ARGS \\) -ls

The car of the variable `find-ls-option' specifies what to
use in place of \"-ls\" as the starting input.

Collect output in the \"*Find*\" buffer.  To kill the job before
it finishes, type \\[kill-find]."
  (interactive
   (list (read-directory-name "Run find in directory: " nil "" t)
	 (read-string "Run find command: "
                      (cons (concat find-program
                                    " . \\(  \\) "
                                    (find-dired--escaped-ls-option))
                            (+ 1 (length find-program) (length " . \\( ")))
		      'find-command-history)))
  (let ((dired-buffers dired-buffers))
    ;; Expand DIR ("" means default-directory), and make sure it has a
    ;; trailing slash.
    (setq dir (file-name-as-directory (expand-file-name dir)))
    ;; Check that it's really a directory.
    (or (file-directory-p dir)
	(error "find-dired needs a directory: %s" dir))
    (pop-to-buffer-same-window (get-buffer-create "*Find*"))

    ;; See if there's still a `find' running, and offer to kill
    ;; it first, if it is.
    (let ((find (get-buffer-process (current-buffer))))
      (when find
	(if (or (not (eq (process-status find) 'run))
		(yes-or-no-p
		 (format-message "A `find' process is running; kill it? ")))
	    (condition-case nil
		(progn
		  (interrupt-process find)
		  (sit-for 1)
		  (delete-process find))
	      (error nil))
	  (error "Cannot have two processes in `%s' at once" (buffer-name)))))

    (widen)
    (kill-all-local-variables)
    (setq buffer-read-only nil)
    (erase-buffer)
    (setq default-directory dir)
    ;; Start the find process.
    (let ((proc (start-file-process-shell-command
                 (buffer-name) (current-buffer) command)))
      ;; Initialize the process marker; it is used by the filter.
      (move-marker (process-mark proc) (point) (current-buffer))
      (set-process-filter proc #'find-dired-filter)
      (set-process-sentinel proc #'find-dired-sentinel))
    (dired-mode dir (cdr find-ls-option))
    (let ((map (make-sparse-keymap)))
      (set-keymap-parent map (current-local-map))
      (define-key map "\C-c\C-k" 'kill-find)
      (use-local-map map))
    (setq-local dired-sort-inhibit t)
    (setq-local revert-buffer-function
                (lambda (_ignore-auto _noconfirm)
                  (find-dired-with-command dir command)))
    ;; Set subdir-alist so that Tree Dired will work:
    (if (fboundp 'dired-simple-subdir-alist)
	;; will work even with nested dired format (dired-nstd.el,v 1.15
	;; and later)
	(dired-simple-subdir-alist)
      ;; else we have an ancient tree dired (or classic dired, where
      ;; this does no harm)
      (setq dired-subdir-alist
            (list (cons default-directory (point-min-marker)))))
    (setq-local dired-subdir-switches find-ls-subdir-switches)
    (setq buffer-read-only nil)
    ;; Subdir headlerline must come first because the first marker in
    ;; subdir-alist points there.
    (insert "  " dir ":\n")
    (when dired-make-directory-clickable
      (dired--make-directory-clickable))
    ;; Make second line a ``find'' line in analogy to the ``total'' or
    ;; ``wildcard'' line.
    (let ((point (point)))
      (insert "  " command "\n")
      (dired-insert-set-properties point (point)))
    (setq buffer-read-only t)
    (setq mode-line-process '(":%s"))))

(defun find-dired--escaped-ls-option ()
  "Return the car of `find-ls-option' escaped for a shell command."
  (if (string-match "\\`\\(.*\\) {} \\(\\\\;\\|\\+\\)\\'"
		    (car find-ls-option))
      (format "%s %s %s"
	      (match-string 1 (car find-ls-option))
	      (shell-quote-argument "{}")
	      find-exec-terminator)
    (car find-ls-option)))

(defun kill-find ()
  "Kill the `find' process running in the current buffer."
  (interactive)
  (let ((find (get-buffer-process (current-buffer))))
    (and find (eq (process-status find) 'run)
	 (eq (process-filter find) #'find-dired-filter)
	 (condition-case nil
	     (delete-process find)
	   (error nil)))))

;;;###autoload
(defun find-name-dired (dir pattern)
  "Search DIR recursively for files matching the globbing PATTERN,
and run Dired on those files.
PATTERN is a shell wildcard (not an Emacs regexp) and need not be quoted.
The default command run (after changing into DIR) is

    find . -name \\='PATTERN\\=' -ls

See `find-name-arg' to customize the arguments."
  (interactive
   "DFind-name (directory): \nsFind-name (filename wildcard): ")
  (find-dired dir (concat find-name-arg " " (shell-quote-argument pattern))))

;; This functionality suggested by
;; From: oblanc@watcgl.waterloo.edu (Olivier Blanc)
;; Subject: find-dired, lookfor-dired
;; Date: 10 May 91 17:50:00 GMT
;; Organization: University of Waterloo

(define-obsolete-function-alias 'lookfor-dired #'find-grep-dired "29.1")
;;;###autoload
(defun find-grep-dired (dir regexp)
  "Find files in DIR that contain matches for REGEXP and start Dired on output.
The command run (after changing into DIR) is

  find . \\( -type f -exec `grep-program' `find-grep-options' \\
    -e REGEXP {} \\; \\) -ls

where the first string in the value of the variable `find-ls-option'
specifies what to use in place of \"-ls\" as the final argument."
  ;; Doc used to say "Thus ARG can also contain additional grep options."
  ;; i) Presumably ARG == REGEXP?
  ;; ii) No it can't have options, since it gets shell-quoted.
  (interactive "DFind-grep (directory): \nsFind-grep (grep regexp): ")
  ;; find -exec doesn't allow shell i/o redirections in the command,
  ;; or we could use `grep -l >/dev/null'
  ;; We use -type f, not ! -type d, to avoid getting screwed
  ;; by FIFOs and devices.  I'm not sure what's best to do
  ;; about symlinks, so as far as I know this is not wrong.
  (find-dired dir
	      (concat "-type f -exec " grep-program " " find-grep-options " -e "
		      (shell-quote-argument regexp)
		      " "
		      (shell-quote-argument "{}")
		      " "
		      ;; Doesn't work with "+".
		      (shell-quote-argument ";"))))

(defun find-dired-filter (proc string)
  ;; Filter for \\[find-dired] processes.
  (let ((buf (process-buffer proc))
	(inhibit-read-only t))
    (if (buffer-name buf)
	(with-current-buffer buf
	  (save-excursion
	    (save-restriction
	      (widen)
	      (let ((buffer-read-only nil)
		    (beg (point-max)))
		(goto-char beg)
		(insert string)
		(goto-char beg)
		(or (looking-at "^")
		    (forward-line 1))
		(while (looking-at "^")
		  (insert "  ")
		  (forward-line 1))
		;; Convert ` ./FILE' to ` FILE'
		;; This would lose if the current chunk of output
		;; starts or ends within the ` ./', so back up a bit:
		(goto-char (- beg 3))	; no error if < 0
		(while (search-forward " ./" nil t)
		  (delete-region (point) (- (point) 2)))
		;; Find all the complete lines in the unprocessed
		;; output and process it to add text properties.
		(goto-char (point-max))
		(if (search-backward "\n" (process-mark proc) t)
		    (progn
		      (dired-insert-set-properties (process-mark proc)
						   (1+ (point)))
		      (move-marker (process-mark proc) (1+ (point)))))))))
      ;; The buffer has been killed.
      (delete-process proc))))

(defun find-dired-sentinel (proc state)
  "Sentinel for \\[find-dired] processes."
  (let ((buf (process-buffer proc)))
    (if (buffer-name buf)
	(with-current-buffer buf
	  (let ((inhibit-read-only t))
	    (save-excursion
              (save-restriction
                (widen)
                (when find-dired-refine-function
                  ;; `find-dired-filter' puts two whitespace characters
                  ;; at the beginning of every line.
                  (narrow-to-region (point) (- (point-max) 2))
                  (funcall find-dired-refine-function)
                  (widen))
                (let ((point (point-max)))
                  (goto-char point)
                  (insert "\n  find "
                          (substring state 0 -1) ; omit \n at end of STATE.
                          " at " (substring (current-time-string) 0 19))
                  (dired-insert-set-properties point (point))))
              (setq mode-line-process
		    (format ":%s" (process-status proc)))
	      ;; Since the buffer and mode line will show that the
	      ;; process is dead, we can delete it now.  Otherwise it
	      ;; will stay around until M-x `list-processes'.
	      (delete-process proc)
	      (force-mode-line-update))))
	  (message "find-dired %s finished." buf))))

(defun find-dired-sort-by-filename ()
  "Sort entries in *Find* buffer by file name lexicographically."
  (sort-subr nil 'forward-line 'end-of-line
             (lambda ()
               (when-let* ((start
                            (next-single-property-change
                             (point) 'dired-filename)))
               (buffer-substring-no-properties start (line-end-position))))))


(provide 'find-dired)

;;; find-dired.el ends here
