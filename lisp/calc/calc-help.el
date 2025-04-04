;;; calc-help.el --- help display functions for Calc  -*- lexical-binding:t -*-

;; Copyright (C) 1990-1993, 2001-2025 Free Software Foundation, Inc.

;; Author: David Gillespie <daveg@synaptics.com>

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

;; This file is autoloaded from calc-ext.el.

(require 'calc-ext)
(require 'calc-macs)

;; Declare functions which are defined elsewhere.
(declare-function Info-goto-node "info" (nodename &optional fork strict-case))
(declare-function Info-last "info" ())


(defun calc-help-prefix (&optional _arg)
  "This key is the prefix for Calc help functions.  See `calc-help-for-help'."
  (interactive "P")
  (or calc-dispatch-help (sit-for echo-keystrokes))
  (let ((key (calc-read-key-sequence
	      (if calc-dispatch-help
                  (substitute-command-keys
		   (concat "Calc Help options: \\`h'elp, \\`i'nfo, \\`t'utorial, "
                           "\\`s'ummary; \\`k'ey, \\`f'unction; \\`?'=more"))
                (format (substitute-command-keys
                         "%s  (Type \\`?' for a list of Calc Help options)")
			(key-description (this-command-keys))))
	      calc-help-map)))
    (setq key (lookup-key calc-help-map key))
    (message "")
    (if key
	(call-interactively key)
      (beep))))

(defun calc-help-for-help (arg)
  "You have typed \\`h', the Calc help character.  Type a Help option:

\\`B'  calc-describe-bindings.  Display a table of all key bindings.
\\`H'  calc-full-help.  Display all \\`?' key messages at once.

\\`I'  calc-info.  Read the Calc manual using the Info system.
\\`T'  calc-tutorial.  Read the Calc tutorial using the Info system.
\\`S'  calc-info-summary.  Read the Calc summary using the Info system.

\\`C'  calc-describe-key-briefly.  Look up the command name for a given key.
\\`K'  calc-describe-key.  Look up a key's documentation in the manual.
\\`F'  calc-describe-function.  Look up a function's documentation in the manual.
\\`V'  calc-describe-variable.  Look up a variable's documentation in the manual.

\\`N'  calc-view-news.  Display Calc history of changes.

\\`C-c'  Describe conditions for copying Calc.
\\`C-d'  Describe how you can get a new copy of Calc or report a bug.
\\`C-w'  Describe how there is no warranty for Calc."
  (interactive "P")
  (if calc-dispatch-help
      (let (key)
	(save-window-excursion
	  (describe-function 'calc-help-for-help)
	  (select-window (get-buffer-window "*Help*"))
	  (while (progn
		   (message (substitute-command-keys
                             (concat
                              "Calc Help options: \\`h'elp, \\`i'nfo, ...  press "
                              "\\`SPC', \\`DEL' to scroll, \\`C-g' to cancel")))
		   (memq (setq key (read-event))
			 '(?  ?\C-h ?\C-? ?\C-v ?\M-v)))
	    (condition-case nil
		(if (memq key '(? ?\C-v))
		    (scroll-up)
		  (scroll-down))
	      (error (beep)))))
	(calc-unread-command key)
	(calc-help-prefix nil))
    (let ((calc-dispatch-help t))
      (calc-help-prefix arg))))

(defun calc-describe-copying ()
  (interactive)
  (calc-info-goto-node "Copying"))

(defun calc-describe-distribution ()
  (interactive)
  (calc-info-goto-node "Reporting Bugs"))

(defun calc-describe-no-warranty ()
  (interactive)
  (calc-info-goto-node "Copying")
  (let ((case-fold-search nil))
    (search-forward "     NO WARRANTY"))
  (beginning-of-line)
  (recenter 0))

(defun calc-describe-bindings ()
  (interactive)
  (describe-bindings)
  (with-current-buffer "*Help*"
    (let ((inhibit-read-only t))
      (goto-char (point-min))
      (when (search-forward "Global bindings:" nil t)
        (forward-line -1)
        (delete-region (point) (point-max)))
      (goto-char (point-min))
      (while
          (re-search-forward
           "\n[a-z] [0-9]\\( .*\n\\)\\([a-z] [0-9]\\1\\)*[a-z] \\([0-9]\\)\\1"
           nil t)
        (let ((dig1 (char-after (1- (match-beginning 1))))
              (dig2 (char-after (match-beginning 3))))
          (delete-region (match-end 1) (match-end 0))
          (goto-char (match-beginning 1))
          (delete-char -1)
          (delete-char 5)
          (insert (format "%c .. %c" (min dig1 dig2) (max dig1 dig2)))))
      (goto-char (point-min)))))

(defun calc-describe-key-briefly (key)
  (interactive "kDescribe key briefly: ")
  (calc-describe-key key t))

(defvar Info-history)

(defun calc-describe-key (key &optional briefly)
  (interactive "kDescribe key: ")
  (let ((defn (if (eq (key-binding key) 'calc-dispatch)
		  (let ((key2 (calc-read-key-sequence
			       (format "Describe key briefly: %s-"
				       (key-description key))
			       calc-dispatch-map)))
		    (setq key (concat key key2))
		    (lookup-key calc-dispatch-map key2))
		(if (eq (key-binding key) 'calc-help-prefix)
		    (let ((key2 (calc-read-key-sequence
				 (format "Describe key briefly: %s-"
					 (key-description key))
				 calc-help-map)))
		      (setq key (concat key key2))
		      (lookup-key calc-help-map key2))
		  (key-binding key))))
	(inv nil)
	(hyp nil)
        calc-summary-indentation)
    (while (or (equal key "I") (equal key "H"))
      (if (equal key "I")
	  (setq inv (not inv))
	(setq hyp (not hyp)))
      (setq key (read-key-sequence (format "Describe key%s:%s%s "
					   (if briefly " briefly" "")
					   (if inv " I" "")
					   (if hyp " H" "")))
	    defn (key-binding key)))
    (let ((desc (key-description key))
	  target)
      (if (string-match "^ESC " desc)
	  (setq desc (concat "M-" (substring desc 4))))
      (while (string-match "^M-# \\(ESC \\|C-\\)" desc)
	(setq desc (concat "M-# " (substring desc (match-end 0)))))
      (if (string-match "\\(DEL\\|LFD\\|RET\\|SPC\\|TAB\\)" desc)
          (setq desc (replace-match "<\\&>" nil nil desc)))
      (if briefly
	  (let ((msg (with-current-buffer (get-buffer-create "*Calc Summary*")
		       (if (= (buffer-size) 0)
			   (progn
			     (message "Reading Calc summary from manual...")
                             (require 'info nil t)
                             (with-temp-buffer
                               (Info-mode)
                               (Info-goto-node "(Calc)Summary")
                               (goto-char (point-min))
                               (forward-line 1)
                               (copy-to-buffer "*Calc Summary*"
                                               (point) (point-max)))
                             (setq buffer-read-only t)))
                       (goto-char (point-min))
                       (setq case-fold-search nil)
                       (re-search-forward "^\\(.*\\)\\[\\.\\. a b")
                       (setq calc-summary-indentation
                             (- (match-end 1) (match-beginning 1)))
		       (goto-char (point-min))
		       (setq target (if (and (string-match "[0-9]\\'" desc)
					     (not (string-match "[d#]" desc)))
					(concat (substring desc 0 -1) "0-9")
				      desc))
		       (if (re-search-forward
			    (format "\n%s%s%s%s[ a-zA-Z]"
				    (make-string (+ calc-summary-indentation 9)
						 ?\.)
				    (if (string-match "M-#" desc) "   "
				      (if inv
					  (if hyp "I H " "  I ")
					(if hyp "  H " "    ")))
				    (regexp-quote target)
				    (make-string (max (- 6 (length target)) 0)
						 ?\ ))
			    nil t)
			   (let (pt)
			     (beginning-of-line)
			     (forward-char calc-summary-indentation)
			     (setq pt (point))
			     (end-of-line)
			     (buffer-substring pt (point)))))))
	    (if msg
		(let ((args (substring msg 0 9))
		      (keys (substring msg 9 19))
		      (prompts (substring msg 19 38))
		      (notes "")
		      (cmd (substring msg 40))
		      msg)
		  (if (string-match "\\` +" args)
		      (setq args (substring args (match-end 0))))
		  (if (string-match " +\\'" args)
		      (setq args (substring args 0 (match-beginning 0))))
		  (if (string-match "\\` +" keys)
		      (setq keys (substring keys (match-end 0))))
		  (if (string-match " +\\'" keys)
		      (setq keys (substring keys 0 (match-beginning 0))))
		  (if (string-match " [0-9,]+\\'" prompts)
		      (setq notes (substring prompts (1+ (match-beginning 0)))
			    prompts (substring prompts 0 (match-beginning 0))))
		  (if (string-match " +\\'" prompts)
		      (setq prompts (substring prompts 0 (match-beginning 0))))
		  (if (string-match "\\` +" prompts)
		      (setq prompts (substring prompts (match-end 0))))
		  (setq msg (format-message
			     "%s:  %s%s`%s'%s%s %s%s"
			     (if (string-match
				  "\\`\\(calc-[-a-zA-Z0-9]+\\) *\\(.*\\)\\'"
				  cmd)
				 (prog1 (math-match-substring cmd 1)
				   (setq cmd (math-match-substring cmd 2)))
			       defn)
			     args (if (equal args "") "" " ")
			     keys
			     (if (equal prompts "") "" " ") prompts
			     (if (equal cmd "") "" " => ") cmd))
		  (message "%s%s%s runs %s%s"
			   (if inv "I " "") (if hyp "H " "") desc
			   msg
			   (if (equal notes "") ""
			     (format "  (?=notes %s)" notes)))
		  (let ((key (read-event)))
		    (if (eq key ??)
			(if (equal notes "")
			    (message "No notes for this command")
			  (while (string-match "," notes)
			    (aset notes (match-beginning 0) ? ))
			  (setq notes (sort (car (read-from-string
						  (format "(%s)" notes)))
					    '<))
			  (with-output-to-temp-buffer "*Help*"
			    (princ (format "%s\n\n" msg))
			    (set-buffer "*Calc Summary*")
			    (re-search-forward "^ *NOTES")
			    (while notes
			      (re-search-forward
			       (format "^ *%d\\. " (car notes)))
			      (beginning-of-line)
			      (let ((pt (point)))
				(forward-line 1)
				(or (re-search-forward "^ ? ?[0-9]+\\. " nil t)
				    (goto-char (point-max)))
				(beginning-of-line)
				(princ (buffer-substring pt (point))))
			      (setq notes (cdr notes)))
			    (help-print-return-message)))
		      (calc-unread-command key))))
	      (if (or (null defn) (integerp defn))
		  (message "%s is undefined" desc)
		(message "%s runs the command %s"
			 desc
			 (if (symbolp defn) defn (prin1-to-string defn))))))
	(if inv (setq desc (concat "I " desc)))
	(if hyp (setq desc (concat "H " desc)))
	(calc-describe-thing desc "Key Index" nil
			     (string-match "[A-Z][A-Z][A-Z]" desc))))))

(defvar calc-help-function-list nil
  "List of functions provided by Calc.")

(defvar calc-help-variable-list nil
  "List of variables provided by Calc.")

(defun calc-help-index-entries (&rest indices)
  "Create a list of entries from the INDICES in the Calc info manual."
  (let ((entrylist '())
        entry)
    (require 'info nil t)
    (dolist (indice indices)
      (ignore-errors
        (with-temp-buffer
          (Info-mode)
          (Info-goto-node (concat "(Calc)" indice " Index"))
          (goto-char (point-min))
          (while (re-search-forward "\n\\* \\(.*\\): " nil t)
            (setq entry (match-string 1))
            (if (and (not (string-match "<[1-9]+>" entry))
                     (not (string-match "(.*)" entry))
                     (not (string= entry "Menu")))
                (unless (assoc entry entrylist)
                  (setq entrylist (cons entry entrylist))))))))
    entrylist))

(defun calc-describe-function (&optional func)
  (interactive)
  (unless calc-help-function-list
    (setq calc-help-function-list
          (calc-help-index-entries "Function" "Command")))
  (or func
      (setq func (completing-read "Describe function: "
                                  calc-help-function-list
                                  nil t)))
  (if (string-match "\\`calc-." func)
      (calc-describe-thing func "Command Index")
    (calc-describe-thing func "Function Index")))

(defun calc-describe-variable (&optional var)
  (interactive)
  (unless calc-help-variable-list
    (setq calc-help-variable-list
          (calc-help-index-entries "Variable")))
  (or var
      (setq var (completing-read "Describe variable: "
                                 calc-help-variable-list
                                 nil t)))
  (calc-describe-thing var "Variable Index"))

(defun calc-describe-thing (thing where &optional target not-quoted)
  (message "Looking for `%s' in %s..." thing where)
  (let ((savewin (current-window-configuration)))
    (calc-info-goto-node where)
    (or (let ((case-fold-search nil))
	  (re-search-forward (format "\n\\* +%s: \\(.*\\)\\."
				     (regexp-quote thing))
			     nil t))
	(and (string-match "\\`\\([a-z ]*\\)[0-9]\\'" thing)
	     (re-search-forward (format "\n\\* +%s[01]-9: \\(.*\\)\\."
					(substring thing 0 -1))
				nil t)
	     (setq thing (format "%s9" (substring thing 0 -1))))
	(progn
          (if Info-history
              (Info-last))
	  (set-window-configuration savewin)
	  (error "Can't find `%s' in %s" thing where)))
    (let (Info-history)
      (Info-goto-node (buffer-substring (match-beginning 1) (match-end 1))))
    (let* ((string-target (or target thing))
           (quoted (format "['`‘]%s['’]" (regexp-quote string-target)))
           (bracketed (format "\\[%s\\]\\|(%s)\\|\\<The[ \n]%s"
                              quoted quoted quoted)))
      (or (let ((case-fold-search nil))
            (or (re-search-forward bracketed nil t)
                (and not-quoted
                     (let ((case-fold-search t))
                       (search-forward string-target nil t)))
                (re-search-forward quoted nil t)
                (search-forward string-target nil t)))
          (let ((case-fold-search t))
            (or (re-search-forward bracketed nil t)
                (re-search-forward quoted nil t)
                (search-forward string-target nil t)))))
    (beginning-of-line)
    (message "Found `%s' in %s" thing where)))

(defun calc-view-news ()
  (interactive)
  (calc-quit)
  (view-emacs-news)
  (re-search-forward "^\\*+ .*\\<Calc\\>" nil t))

(defvar calc-help-long-names '((?b . "binary/business")
			       (?g . "graphics")
			       (?j . "selection")
			       (?k . "combinatorics/statistics")
			       (?u . "units/statistics")))

(defun calc-full-help ()
  (interactive)
  (with-output-to-temp-buffer "*Help*"
    (princ "GNU Emacs Calculator.\n")
    (princ "  By Dave Gillespie.\n")
    (princ (format "  %s\n\n" emacs-copyright))
    (princ (format-message "Type `h s' for a more detailed summary.\n"))
    (princ (format-message
            "Or type `h i' to read the full Calc manual on-line.\n\n"))
    (princ "Basic keys:\n")
    (let* ((calc-full-help-flag t))
      (mapc (lambda (x)
              (princ (format
                      "  %s\n"
                      (substitute-command-keys x))))
	    (nreverse (cdr (reverse (cdr (calc-help))))))
      (mapc (lambda (prefix)
              (let ((msgs (ignore-errors (funcall prefix))))
                (if (car msgs)
                    (princ
                     (if (eq (nth 2 msgs) ?v)
                         (format-message
                          "\n`v' or `V' prefix (vector/matrix) keys: \n")
                       (if (nth 2 msgs)
                           (format-message
                            "\n`%c' prefix (%s) keys:\n"
                            (nth 2 msgs)
                            (or (cdr (assq (nth 2 msgs)
                                           calc-help-long-names))
                                (nth 1 msgs)))
                         (format "\n%s-modified keys:\n"
                                 (capitalize (nth 1 msgs)))))))
                (mapcar (lambda (x)
                          (princ (format
                                  "  %s\n"
                                  (substitute-command-keys x))))
                        (car msgs))))
	    '(calc-inverse-prefix-help
	      calc-hyperbolic-prefix-help
	      calc-inv-hyp-prefix-help
              calc-option-prefix-help
	      calc-a-prefix-help
	      calc-b-prefix-help
	      calc-c-prefix-help
	      calc-d-prefix-help
	      calc-f-prefix-help
	      calc-g-prefix-help
	      calc-h-prefix-help
	      calc-j-prefix-help
	      calc-k-prefix-help
	      calc-l-prefix-help
	      calc-m-prefix-help
	      calc-r-prefix-help
	      calc-s-prefix-help
	      calc-t-prefix-help
	      calc-u-prefix-help
	      calc-v-prefix-help
	      calc-shift-Y-prefix-help
	      calc-shift-Z-prefix-help
	      calc-z-prefix-help)))
    (help-print-return-message)))

(defun calc-h-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`h'elp; \\`b'indings; \\`i'nfo, \\`t'utorial, \\`s'ummary; \\`n'ews"
     "describe: \\`k'ey, \\`c' (briefly), \\`f'unction, \\`v'ariable")
   "help" ?h))

(defun calc-inverse-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`I' + \\`S' (arcsin), \\`C' (arccos), \\`T' (arctan); \\`Q' (square)"
     "\\`I' + \\`E' (ln), \\`L' (exp), \\`B' (alog: B^X); \\`f E' (lnp1), \\`f L' (expm1)"
     "\\`I' + \\`F' (ceiling), \\`R' (truncate); \\`a S' (invert func)"
     "\\`I' + \\`a m' (match-not); \\`c h' (from-hms); \\`k n' (prev prime)"
     "\\`I' + \\`f G' (gamma-Q); \\`f e' (erfc); \\`k B' (etc., lower-tail dists)"
     "\\`I' + \\`V S' (reverse sort); \\`V G' (reverse grade)"
     "\\`I' + \\`v s' (remove subvec); \\`v h' (tail)"
     "\\`I' + \\`t' + (alt sum), \\`t M' (mean with error)"
     "\\`I' + \\`t S' (pop std dev), \\`t C' (pop covar)")
   "inverse" nil))

(defun calc-hyperbolic-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`H' + \\`S' (sinh), \\`C' (cosh), \\`T' (tanh); \\`E' (exp10), \\`L' (log10)"
     "\\`H' + \\`F' (float floor), \\`R' (float round); \\`P' (constant \"e\")"
     "\\`H' + \\`a d' (total derivative); \\`k c' (permutations)"
     "\\`H' + \\`k b' (bern-poly), \\`k e' (euler-poly); \\`k s' (stirling-2)"
     "\\`H' + \\`f G' (gamma-g), \\`f B' (beta-B); \\`v h' (rhead), \\`v k' (rcons)"
     "\\`H' + \\`v e' (expand w/filler); \\`V H' (weighted histogram)"
     "\\`H' + \\`a S' (general solve eqn), \\`j I' (general isolate)"
     "\\`H' + \\`a R' (widen/root), \\`a N' (widen/min), \\`a X' (widen/max)"
     "\\`H' + \\`t M' (median), \\`t S' (variance), \\`t C' (correlation coef)"
     "\\`H' + \\`c' \\`f'/\\`F'/\\`c' (pervasive float/frac/clean)")
   "hyperbolic" nil))

(defun calc-inv-hyp-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`I H' + \\`S' (arcsinh), \\`C' (arccosh), \\`T' (arctanh)"
     "\\`I H' + \\`E' (log10), \\`L' (exp10); \\`f G' (gamma-G)"
     "\\`I H' + \\`F' (float ceiling), \\`R' (float truncate)"
     "\\`I H' + \\`t S' (pop variance)"
     "\\`I H' + \\`a S' (general invert func); \\`v h' (rtail)")
   "inverse-hyperbolic" nil))

(defun calc-option-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("")
   "option" nil))

(defun calc-f-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("mi\\`n', ma\\`x'; \\`h'ypot; \\`i'm, \\`r'e; \\`s'ign; \\`[', \\`]' (incr/decr)"
     "\\`g'amma, \\`b'eta, \\`e'rf, bessel\\`j', bessel\\`y'"
     "int-s\\`Q'rt; \\`I'nt-log, \\`E'xp(x)-1, \\`L'n(x+1); arc\\`T'an2"
     "\\`A'bssqr; \\`M'antissa, e\\`X'ponent, \\`S'cale"
     "SHIFT + incomplete: Gamma-P, Beta-I")
   "functions" ?f))


(defun calc-s-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`s'tore, in\\`t'o, \\`x'chg, \\`u'nstore; \\`r'ecall, \\`0'-\\`9'; \\`:' (:=); \\`=' (=>)"
     "\\`l'et; \\`c'opy, \\`k'=copy constant; \\`d'eclare; \\`i'nsert, \\`p'erm; \\`e'dit"
     "\\`n'egate, \\`+', \\`-', \\`*', \\`/', \\`^', \\`&', \\`|', \\`[', \\`]'; Map"
     "\\`D'ecls, \\`G'enCount, \\`T'imeZone, \\`H'olidays; \\`I'ntegLimit"
     "\\`L'ineStyles, \\`P'ointStyles, plot\\`R'ejects; \\`U'nits"
     "\\`E'val-, \\`A'lgSimp-, e\\`X'tSimp-, \\`F'itRules")
   "store" ?s))

(defun calc-r-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("digits \\`0'-\\`9': recall, same as \\`s r' \\`0'-\\`9'"
     "\\`s'ave to register, \\`i'nsert from register")
   "recall/register" ?r))


(defun calc-j-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`s'elect, \\`a'dditional, \\`o'nce; e\\`v'al, \\`f'ormula; \\`r'ewrite"
     "\\`m'ore, \\`l'ess, \\`1'-\\`9', \\`n'ext, \\`p'revious"
     "\\`u'nselect, \\`c'lear; \\`d'isplay; \\`e'nable; \\`b'reakable"
     "\\=' (replace), \\=` (edit), \\`+', \\`-', \\`*', \\`/', \\`RET' (grab), \\`DEL'"
     "swap: \\`L'eft, \\`R'ight; maybe: \\`S'elect, \\`O'nce"
     "\\`C'ommute, \\`M'erge, \\`D'istrib, jump-\\`E'qn, \\`I'solate"
     "\\`N'egate, \\`&' (invert); \\`U'npack")
   "select" ?j))


(defun calc-a-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`s'implify, \\`e'xtended-simplify, e\\`v'al; \\`\"' (exp-formula)"
     "e\\`x'pand, \\`c'ollect, \\`f'actor, \\`a'part, \\`n'orm-rat"
     "\\`g' (GCD), \\`/', \\`\\', \\`%' (polys); \\`p'olint"
     "\\`d'erivative, \\`i'ntegral, \\`t'aylor; \\`_' (subscr)"
     "su\\`b'stitute; \\`r'ewrite, \\`m'atch"
     "\\`S'olve; \\`R'oot, mi\\`N', ma\\`X'; \\`P'oly-roots; \\`F'it"
     "\\`M'ap; \\`T'abulate, \\`+' (sum), \\`*' (prod); num-\\`I'nteg"
     "relations: \\`=', \\`#' (not =), \\`<', \\`>', \\`[' (< or =), \\`]' (> or =)"
     "logical: \\`&' (and), \\`|' (or), \\`!' (not); \\`:' (if)"
     "misc: \\`{' (in-set); \\`.' (rmeq)")
   "algebra" ?a))


(defun calc-b-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`a'nd, \\`o'r, \\`x'or, \\`d'iff, \\`n'ot; \\`w'ordsize, \\`c'lip"
     "\\`l'shift, \\`r'shift, ro\\`t'ate; signed \\`L'shift, \\`R'shift"
     "business: \\`P'v, \\`N'pv, \\`F'v, p\\`M't, \\`#'pmts, ra\\`T'e, \\`I'rr"
     "business: \\`S'ln, s\\`Y'd, \\`D'db; \\`%'ch")
   "binary/bus" ?b))


(defun calc-c-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`d'eg, \\`r'ad, \\`h'ms; \\`f'loat; \\`p'olar/rect; \\`c'lean, \\`0'-\\`9'; \\`%'"
     "\\`F'raction")
   "convert" ?c))


(defun calc-d-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`g'roup, \\`,'; \\`n'ormal, \\`f'ix, \\`s'ci, \\`e'ng, \\`.'; \\`o'ver"
     "\\`r'adix, \\`z'eros, \\`2', \\`8', \\`0', \\`6'; \\`h'ms; \\`d'ate; \\`c'omplex, \\`i', \\`j'"
     "\\`w'hy; \\`l'ine-nums, line-\\`b'reaks; \\`<', \\`=', \\`>' (justify); \\`p'lain"
     "\\`\"' (strings); \\`t'runcate, \\`[', \\`]'; \\`SPC' (refresh), \\`RET', \\`@'"
     "language: \\`N'ormal, \\`O'ne-line, \\`B'ig, \\`U'nformatted"
     "language: \\`C', \\`P'ascal, \\`F'ortran; \\`T'eX, \\`L'aTeX, \\`E'qn"
     "language: \\`Y'acas, \\`X'=Maxima, \\`A'=Giac"
     "language: \\`M'athematica, \\`W'=Maple")
   "display" ?d))


(defun calc-g-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`f'ast; \\`a'dd, \\`d'elete, \\`j'uggle; \\`p'lot, \\`c'lear; \\`q'uit"
     "\\`h'eader, \\`n'ame, \\`g'rid, \\`b'order, \\`k'ey; \\`v'iew-commands, \\`x'-display"
     "x-axis: \\`r'ange, \\`t'itle, \\`l'og, \\`z'ero; line\\`s'tyle"
     "y-axis: \\`R'ange, \\`T'itle, \\`L'og, \\`Z'ero; point\\`S'tyle"
     "\\`P'rint; \\`D'evice, \\`O'utput-file; \\`X'-geometry"
     "\\`N'um-pts; \\`C'ommand, \\`K'ill, \\`V'iew-trail"
     "3d: \\`F'ast, \\`A'dd; z-axis: \\`C-r' (range), \\`C-t' (title), \\`C-l' (log)")
   "graph" ?g))


(defun calc-k-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`g' (GCD), \\`l' (LCM); \\`c'hoose (binomial), \\`d'ouble-factorial"
     "\\`r'andom, random-\\`a'gain, s\\`h'uffle"
     "\\`f'actors, \\`p'rime-test, \\`n'ext-prime, \\`t'otient, \\`m'oebius"
     "\\`b'ernoulli, \\`e'uler, \\`s'tirling"
     "\\`E'xtended-gcd"
     "dists: \\`B'inomial, \\`C'hi-square, \\`F', \\`N'ormal"
     "dists: \\`P'oisson, student\\='s-\\`T'")
   "combinatorics" ?k))


(defun calc-m-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`d'eg, \\`r'ad, \\`h' (HMS); \\`f'rac; \\`p'olar; \\`i'nf; \\`a'lg, \\`t'otal; \\`s'ymb; \\`v'ec/mat"
     "\\`w'orking; \\`x'tensions; \\`m'ode-save; preserve \\`e'mbedded modes"
     "\\`S'hifted-prefixes, mode-\\`F'ilename; \\`R'ecord; re\\`C'ompute"
     "simplify: \\`O'ff, \\`N'um, bas\\`I'c, \\`A'lgebraic, \\`B'in, \\`E'xt, \\`U'nits")
   "mode" ?m))


(defun calc-t-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`d'isplay; \\`f'wd, \\`b'ack; \\`n'ext, \\`p'rev, \\`h'ere, \\`[', \\`]'; \\`y'ank"
     "\\`s'earch, \\`r'ev; \\`i'n, \\`o'ut; \\`<', \\`>'; \\`k'ill; \\`m'arker; \\`.' (abbrev)"
     "time: \\`N'ow; \\`P'art; \\`D'ate, \\`J'ulian, \\`U'nix, \\`C'zone"
     "time: new\\`W'eek, new\\`M'onth, new\\`Y'ear; \\`I'ncmonth"
     "time: \\`+', \\`-' (business days)"
     "digits \\`0'-\\`9': store-to, same as \\`s t' \\`0'-\\`9'")
   "trail/time" ?t))


(defun calc-u-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`s'implify, \\`c'onvert, co\\`n'vert exact, \\`t'emperature-convert, \\`b'ase-units"
     "\\`a'utorange; \\`r'emove, e\\`x'tract; \\`e'xplain; \\`v'iew-table; \\`0'-\\`9'"
     "\\`d'efine, \\`u'ndefine, \\`g'et-defn, \\`p'ermanent"
     "\\`V'iew-table-other-window"
     "stat: \\`M'ean, \\`G'-mean, \\`S'td-dev, \\`C'ovar, ma\\`X', mi\\`N'"
     "stat: \\`+' (sum), \\`-' (asum), \\`*' (prod), \\`#' (count)")
   "units/stat" ?u))

(defun calc-l-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`q'uantity, \\`d' (DB level), \\`n' (NP level)"
     "\\`+', \\`-', \\`*', \\`/'"
     "\\`s'cientific pitch notation, \\`m'idi number, \\`f'requency"
     )
   "log units" ?l))

(defun calc-v-prefix-help ()
  (interactive)
  (calc-do-prefix-help
   '("\\`p'ack, \\`u'npack, \\`i'dentity, \\`d'iagonal, inde\\`x', \\`b'uild"
     "\\`r'ow, \\`c'olumn, \\`s'ubvector; \\`l'ength; \\`f'ind; \\`m'ask, \\`e'xpand"
     "\\`t'ranspose, \\`a'rrange, re\\`v'erse; \\`h'ead, \\`k'ons; r\\`n'orm"
     "\\`D'et, \\`&' (inverse), \\`L'UD, \\`T'race, con\\`J'trn, \\`C'ross"
     "\\`S'ort, \\`G'rade, \\`H'istogram; c\\`N'orm"
     "\\`A'pply, \\`M'ap, \\`R'educe, acc\\`U'm, \\`I'nner-, \\`O'uter-prod"
     "sets: \\`V' (union), \\`^' (intersection), \\`-' (diff)"
     "sets: \\`X'or, \\`~' (complement), \\`F'loor, \\`E'num"
     "sets: \\`:' (span), \\`#' (card), \\`+' (rdup)"
     "\\`<', \\`=', \\`>' (justification); \\`,' (commas); \\`[', \\`{', \\`(' (brackets)"
     "\\`}' (matrix brackets); \\`.' (abbreviate); \\`/' (multi-lines)")
   "vec/mat" ?v))

(provide 'calc-help)

;;; calc-help.el ends here
