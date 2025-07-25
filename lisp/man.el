;;; man.el --- browse UNIX manual pages -*- lexical-binding: t -*-

;; Copyright (C) 1993-2025 Free Software Foundation, Inc.

;; Author: Barry A. Warsaw <bwarsaw@cen.com>
;; Maintainer: emacs-devel@gnu.org
;; Keywords: help
;; Adapted-By: ESR, pot

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

;; This code provides a function, `man', with which you can browse
;; UNIX manual pages.  Formatting is done in background so that you
;; can continue to use your Emacs while processing is going on.
;;
;; The mode also supports hypertext-like following of manual page SEE
;; ALSO references, and other features.  See below or type `?' in a
;; manual page buffer for details.

;; ========== Features ==========
;; + Runs "man" in the background and pipes the results through a
;;   series of sed and awk scripts so that all retrieving and cleaning
;;   is done in the background.  The cleaning commands are configurable.
;; + Syntax is the same as Un*x man
;; + Functionality is the same as Un*x man, including "man -k" and
;;   "man <section>", etc.
;; + Provides a manual browsing mode with keybindings for traversing
;;   the sections of a manpage, following references in the SEE ALSO
;;   section, and more.
;; + Multiple manpages created with the same man command are put into
;;   a narrowed buffer circular list.

;; ========== Credits and History ==========
;; In mid 1991, several people posted some interesting improvements to
;; man.el from the standard Emacs 18.57 distribution.  I liked many of
;; these, but wanted everything in one single package, so I decided
;; to incorporate them into a single manual browsing mode.  While
;; much of the code here has been rewritten, and some features added,
;; these folks deserve lots of credit for providing the initial
;; excellent packages on which this one is based.

;; Nick Duffek <duffek@chaos.cs.brandeis.edu>, posted a very nice
;; improvement which retrieved and cleaned the manpages in a
;; background process, and which correctly deciphered such options as
;; man -k.

;; Eric Rose <erose@jessica.stanford.edu>, submitted manual.el which
;; provided a very nice manual browsing mode.

;; This package was available as `superman.el' from the LCD package
;; for some time before it was accepted into Emacs 19.  The entry
;; point and some other names have been changed to make it a drop-in
;; replacement for the old man.el package.

;; Francesco Potortì <pot@cnuce.cnr.it> cleaned it up thoroughly,
;; making it faster, more robust and more tolerant of different
;; systems' man idiosyncrasies.

;; ============= TODO ===========
;; - Add a command for printing.
;; - The awk script deletes multiple blank lines.  This behavior does
;;   not allow one to understand if there was indeed a blank line at the
;;   end or beginning of a page (after the header, or before the
;;   footer).  A different algorithm should be used.  It is easy to
;;   compute how many blank lines there are before and after the page
;;   headers, and after the page footer.  But it is possible to compute
;;   the number of blank lines before the page footer by heuristics
;;   only.  Is it worth doing?
;; - Allow a user option to mean that all the manpages should go in
;;   the same buffer, where they can be browsed with M-n and M-p.


;;; Code:

(require 'ansi-color)
(require 'cl-lib)

(defgroup man nil
  "Browse UNIX manual pages."
  :prefix "Man-"
  :group 'external
  :group 'help)

(defcustom Man-prefer-synchronous-call nil
  "Whether to call the Un*x \"man\" program synchronously.
When this is non-nil, call the \"man\" program synchronously
(rather than asynchronously, which is the default behavior)."
  :type 'boolean
  :version "30.1")

(defcustom Man-support-remote-systems nil
  "Whether to call the Un*x \"man\" program on remote systems.
When this is non-nil, call the \"man\" program on the remote
system determined by `default-directory'."
  :type 'boolean
  :version "30.1")

(defcustom Man-filter-list nil
  "Manpage cleaning filter command phrases.
This variable contains a list of the following form:

  ((command-string phrase-string*)*)

Each phrase-string is concatenated onto the command-string to form a
command filter.  The (standard) output (and standard error) of the Un*x
man command is piped through each command filter in the order the
commands appear in the association list.  The final output is placed in
the manpage buffer."
  :type '(repeat (list (string :tag "Command String")
		       (repeat :inline t
			       (string :tag "Phrase String")))))

(defvar Man-uses-untabify-flag t
  "Non-nil means use `untabify' instead of `Man-untabify-command'.")
(defvar Man-sed-script nil
  "Script for sed to nuke backspaces and ANSI codes from manpages.")

(defcustom Man-fontify-manpage-flag t
  "Non-nil means make up the manpage with fonts."
  :type 'boolean)

(defvar Man-cache-completion-results-flag (eq system-type 'darwin)
  "Non-nil means cache completion results for `man'.
This is non-nil by default on macOS, because getting and filtering
\"man -k ^\" results is slower there than on GNU/Linux.")

(defvar Man-ansi-color-basic-faces-vector
  [nil Man-overstrike nil Man-underline Man-underline nil nil Man-reverse]
  "The value used here for `ansi-color-basic-faces-vector'.")

(defvar Man-ansi-color-map
  (with-no-warnings
    (let ((ansi-color-faces-vector
           [ default Man-overstrike default Man-underline
             Man-underline default default Man-reverse ]))
      (ansi-color-make-color-map)))
  "The value formerly used here for `ansi-color-map'.
This variable is obsolete.  To customize the faces used by ansi-color,
set `Man-ansi-color-basic-faces-vector'.")
(make-obsolete-variable 'Man-ansi-color-map
                        'Man-ansi-color-basic-faces-vector "28.1")

(defcustom Man-notify-method 'friendly
  "Selects the behavior when manpage is ready.
This variable may have one of the following values, where (sf) means
that the frames are switched, so the manpage is displayed in the frame
where the man command was called from:

newframe   -- put the manpage in its own frame (see `Man-frame-parameters')
pushy      -- make the manpage the current buffer in the current window
bully      -- make the manpage the current buffer and only window (sf)
aggressive -- make the manpage the current buffer in the other window (sf)
friendly   -- display manpage in the other window but don't make current (sf)
thrifty    -- reuse an existing manpage window if possible (sf)
polite     -- don't display manpage, but prints message and beep when ready
quiet      -- like `polite', but don't beep
meek       -- make no indication that the manpage is ready

Any other value of `Man-notify-method' is equivalent to `meek'."
  :type '(radio (const newframe) (const pushy) (const bully)
		(const aggressive) (const friendly) (const thrifty)
		(const polite) (const quiet) (const meek)))

(defcustom Man-width nil
  "Number of columns for which manual pages should be formatted.
If nil, use the width of the window where the manpage is displayed.
If non-nil, use the width of the frame where the manpage is displayed.
The value also can be a positive integer for a fixed width."
  :type '(choice (const :tag "Window width" nil)
                 (const :tag "Frame width" t)
                 (integer :tag "Fixed width" :value 65)))

(defcustom Man-width-max 80
  "Maximum number of columns allowed for the width of manual pages.
It defines the maximum width for the case when `Man-width' is customized
to a dynamically calculated value depending on the frame/window width.
If the width calculated for `Man-width' is larger than the maximum width,
it will be automatically reduced to the width defined by this variable.
When nil, there is no limit on maximum width."
  :type '(choice (const :tag "No limit" nil)
                 (integer :tag "Max width" :value 80))
  :version "27.1")

(defcustom Man-frame-parameters nil
  "Frame parameter list for creating a new frame for a manual page."
  :type '(repeat (cons :format "%v"
		       (symbol :tag "Parameter")
		       (sexp :tag "Value"))))

(defcustom Man-downcase-section-letters-flag t
  "Non-nil means letters in sections are converted to lower case.
Some Un*x man commands can't handle uppercase letters in sections, for
example \"man 2V chmod\", but they are often displayed in the manpage
with the upper case letter.  When this variable is t, the section
letter (e.g., \"2V\") is converted to lowercase (e.g., \"2v\") before
being sent to the man background process."
  :type 'boolean)

(defcustom Man-circular-pages-flag t
  "Non-nil means the manpage list is treated as circular for traversal."
  :type 'boolean)

(defcustom Man-section-translations-alist
  (list
   '("3C++" . "3")
   ;; Some systems have a real 3x man section, so let's comment this.
   ;; '("3X" . "3")                        ; Xlib man pages
   '("3X11" . "3")
   '("1-UCB" . ""))
  "Association list of bogus sections to real section numbers.
Some manpages (e.g. the Sun C++ 2.1 manpages) have section numbers in
their references which Un*x `man' does not recognize.  This
association list is used to translate those sections, when found, to
the associated section number."
  :type '(repeat (cons (string :tag "Bogus Section")
		       (string :tag "Real Section"))))

(defcustom Man-header-file-path t
  "C Header file search path used in Man."
  :version "31.1"
  :type '(choice (repeat string)
                 (const :tag "Use 'ffap-c-path'" t)))

(defcustom Man-name-local-regexp (concat "^" (regexp-opt '("NOM" "NAME")) "$")
  "Regexp that matches the text that precedes the command's name.
Used in `bookmark-set' to get the default bookmark name."
  :version "24.1"
  :type 'regexp :group 'bookmark)

(defcustom manual-program "man"
  "Program used by `man' to produce man pages."
  :type 'string)

(defcustom Man-untabify-command "pr"
  "Program used by `man' for untabifying."
  :type 'string)

(defcustom Man-untabify-command-args (list "-t" "-e")
  "List of arguments to be passed to `Man-untabify-command' (which see)."
  :type '(repeat string))

(defcustom Man-sed-command "sed"
  "Program used by `man' to process sed scripts."
  :type 'string)

(defcustom Man-awk-command "awk"
  "Program used by `man' to process awk scripts."
  :type 'string)

;; This is for people who have UTF-8 encoded man pages in non-UTF-8
;; locales, or who use Cygwin 'man' command from a native MS-Windows
;; build of Emacs.
(defcustom Man-coding-system nil
  "Coding-system to decode output from the commands run by `man'.
If this is nil, `man' will use `locale-coding-system'."
  :type 'coding-system
  :version "26.1")

(defcustom Man-mode-hook nil
  "Hook run when Man mode is enabled."
  :type 'hook)

(defcustom Man-cooked-hook nil
  "Hook run after removing backspaces but before `Man-mode' processing."
  :type 'hook)

(defvar Man-name-regexp "[-[:alnum:]_­+[@][-[:alnum:]_.:­+]*"
  "Regular expression describing the name of a manpage (without section).")

(defvar Man-section-regexp "[0-9][a-zA-Z0-9+]*\\|[LNln]"
  "Regular expression describing a manpage section within parentheses.")

(defvar Man-page-header-regexp
  (if (string-match "-solaris2\\." system-configuration)
      (concat "^[-[:alnum:]_].*[ \t]\\(" Man-name-regexp
	      "(\\(" Man-section-regexp "\\))\\)$")
    (concat "^[ \t]*\\(" Man-name-regexp
	    "(\\(" Man-section-regexp "\\))\\).*\\1"))
  "Regular expression describing the heading of a page.")

(defvar Man-heading-regexp "^\\([[:upper:]][[:upper:]0-9 /-]+\\)$"
  "Regular expression describing a manpage heading entry.")

(defvar Man-see-also-regexp "\\(SEE ALSO\\|VOIR AUSSI\\|SIEHE AUCH\\|VÉASE TAMBIÉN\\|VEJA TAMBÉM\\|VEDERE ANCHE\\|ZOBACZ TAKŻE\\|İLGİLİ BELGELER\\|参照\\|参见 SEE ALSO\\|參見 SEE ALSO\\)"
  "Regular expression for SEE ALSO heading (or your equivalent).
This regexp should not start with a `^' character.")

;; This used to have leading space [ \t]*, but was removed because it
;; causes false page splits on an occasional NAME with leading space
;; inside a manpage.  And `Man-heading-regexp' doesn't have [ \t]* anyway.
(defvar Man-first-heading-regexp "^NAME$\\|^[ \t]*No manual entry for.*$"
  "Regular expression describing first heading on a manpage.
This regular expression should start with a `^' character.")

(defvar Man-reference-regexp
  (concat "\\(" Man-name-regexp
	  "\\(\\([-‐]\n\\)?[ \t]+" Man-name-regexp "\\)*\\)[ \t]*(\\("
	  Man-section-regexp "\\))")
  "Regular expression describing a reference to another manpage.")

(defvar Man-apropos-regexp
  (concat "\\[\\(" Man-name-regexp "\\)\\][ \t]*(\\(" Man-section-regexp "\\))")
  "Regular expression describing a reference to manpages in \"man -k output\".")

(defvar Man-synopsis-regexp "SYNOPSIS"
  "Regular expression for SYNOPSIS heading (or your equivalent).
This regexp should not start with a `^' character.")

(defvar Man-files-regexp "FILES\\>"
  ;; Add \> so as not to match mount(8)'s FILESYSTEM INDEPENDENT MOUNT OPTIONS.
  "Regular expression for FILES heading (or your equivalent).
This regexp should not start with a `^' character.")

(defvar Man-include-regexp "#[ \t]*include[ \t]*"
  "Regular expression describing the #include (directive of cpp).")

(defvar Man-file-name-regexp "[^<>\", \t\n]+"
  "Regular expression describing <> in #include line (directive of cpp).")

(defvar Man-normal-file-prefix-regexp "[/~$]"
  "Regular expression describing a file path appeared in FILES section.")

(defvar Man-header-regexp
  (concat "\\(" Man-include-regexp "\\)"
          "[<\"]"
          "\\(" Man-file-name-regexp "\\)"
          "[>\"]")
  "Regular expression describing references to header files.")

(defvar Man-normal-file-regexp
  (concat Man-normal-file-prefix-regexp Man-file-name-regexp)
  "Regular expression describing references to normal files.")

;; This includes the section as an optional part to catch hyphenated
;; references to manpages.
(defvar Man-hyphenated-reference-regexp
  (concat "\\(" Man-name-regexp "\\)\\((\\(" Man-section-regexp "\\))\\)?")
  "Regular expression describing a reference in the SEE ALSO section.")

(defcustom Man-switches ""
  "Switches passed to the man command, as a single string.
For example, the -a switch lets you see all the manpages for a
specified subject, if your `man' program supports it."
  :type 'string)

(defvar Man-specified-section-option
  (if (string-match "-solaris[0-9.]*$" system-configuration)
      "-s"
    "")
  "Option that indicates a specified a manual section name.")

(defvar Man-support-local-filenames 'auto-detect
  "Internal cache for the value of the function `Man-support-local-filenames'.
`auto-detect' means the value is not yet determined.
Otherwise, the value is whatever the function
`Man-support-local-filenames' should return.")

(defcustom man-imenu-title "Contents"
  "The title to use if man adds a Contents menu to the menubar."
  :version "24.4"
  :type 'string)


;; faces

(defgroup man-faces nil
  "Man mode faces, used by \\[man]."
  :prefix "Man-"
  :group 'man)

(defface Man-overstrike
  '((t (:inherit bold)))
  "Face to use when fontifying overstrike."
  :group 'man-faces
  :version "24.3")

(defface Man-underline
  '((t (:inherit underline)))
  "Face to use when fontifying underlining."
  :group 'man-faces
  :version "24.3")

(defface Man-reverse
  '((t (:inherit highlight)))
  "Face to use when fontifying reverse video."
  :group 'man-faces
  :version "24.3")


;; other variables and keymap initializations
(defvar-local Man-original-frame nil)
(defvar-local Man-arguments nil)
(put 'Man-arguments 'permanent-local t)

(defvar-local Man--sections nil)
(defvar-local Man--refpages nil)
(defvar-local Man-page-list nil)
(defvar-local Man-current-page 0)
(defvar-local Man-page-mode-string "1 of 1")

(defconst Man-sysv-sed-script "\
/\b/ {	s/_\b//g
	s/\b_//g
        s/o\b+/o/g
        s/+\bo/o/g
	:ovstrk
	s/\\(.\\)\b\\1/\\1/g
	t ovstrk
	}
/\e\\[[0-9][0-9]*m/ s///g"
  "Script for sysV-like sed to nuke backspaces and ANSI codes from manpages.")

(defconst Man-berkeley-sed-script "\
/\b/ {	s/_\b//g\\
	s/\b_//g\\
        s/o\b+/o/g\\
        s/+\bo/o/g\\
	:ovstrk\\
	s/\\(.\\)\b\\1/\\1/g\\
	t ovstrk\\
	}\\
/\e\\[[0-9][0-9]*m/ s///g"
  "Script for berkeley-like sed to nuke backspaces and ANSI codes from manpages.")

(defvar Man-topic-history nil "Topic read history.")

(defvar Man-mode-syntax-table
  (let ((table (copy-syntax-table (standard-syntax-table))))
    (modify-syntax-entry ?. "w" table)
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?: "w" table)	; for PDL::Primitive in Perl man pages
    table)
  "Syntax table used in Man mode buffers.")

(defvar-keymap Man-mode-map
  :doc "Keymap for Man mode."
  :suppress t
  :parent (make-composed-keymap button-buffer-map special-mode-map)
  "n"   #'Man-next-section
  "p"   #'Man-previous-section
  "M-n" #'Man-next-manpage
  "M-p" #'Man-previous-manpage
  "."   #'beginning-of-buffer
  "r"   #'Man-follow-manual-reference
  "g"   #'Man-goto-section
  "s"   #'Man-goto-see-also-section
  "k"   #'Man-kill
  "u"   #'Man-update-manpage
  "m"   #'man
  ;; Not all the man references get buttons currently.  The text in the
  ;; manual page can contain references to other man pages
  "RET" #'man-follow

  :menu
  '("Man"
    ["Next Section" Man-next-section t]
    ["Previous Section" Man-previous-section t]
    ["Go To Section..." Man-goto-section t]
    ["Go To \"SEE ALSO\" Section" Man-goto-see-also-section
     :active (cl-member Man-see-also-regexp Man--sections
                        :test #'string-match-p)]
    ["Follow Reference..." Man-follow-manual-reference
     :active Man--refpages
     :help "Go to a manpage referred to in the \"SEE ALSO\" section"]
    "--"
    ["Next Manpage" Man-next-manpage
     :active (> (length Man-page-list) 1)]
    ["Previous Manpage" Man-previous-manpage
     :active (> (length Man-page-list) 1)]
    "--"
    ["Man..." man t]
    ["Kill Buffer" Man-kill t]
    ["Quit" quit-window t]))

;; buttons
(define-button-type 'Man-abstract-xref-man-page
  'follow-link t
  'help-echo "mouse-2, RET: display this man page"
  'func nil
  'action #'Man-xref-button-action)

(defun Man-xref-button-action (button)
  (let ((target (button-get button 'Man-target-string)))
    (funcall
     (button-get button 'func)
     (cond ((null target)
	    (button-label button))
	   ((functionp target)
	    (funcall target (button-start button)))
	   (t target)))))

(define-button-type 'Man-xref-man-page
  :supertype 'Man-abstract-xref-man-page
  'func 'man-follow)


(define-button-type 'Man-xref-header-file
    'action (lambda (button)
              (let ((w (button-get button 'Man-target-string)))
                (unless (Man-view-header-file w)
                  (error "Cannot find header file: %s" w))))
    'follow-link t
    'help-echo "mouse-2: display this header file")

(define-button-type 'Man-xref-normal-file
  'action (lambda (button)
	    (let ((f (concat (file-remote-p default-directory)
                             (substitute-in-file-name
		              (button-get button 'Man-target-string)))))
	      (if (file-exists-p f)
		  (if (file-readable-p f)
		      (view-file f)
		    (error "Cannot read a file: %s" f))
		(error "Cannot find a file: %s" f))))
  'follow-link t
  'help-echo "mouse-2: display this file")


;; ======================================================================
;; utilities

(defun Man-default-directory ()
  "Return a default directory according to `Man-support-remote-systems'."
  ;; Ensure that `default-directory' exists and is readable.
  ;; We assume, that this function is always called inside the `man'
  ;; command, so that we can check `current-prefix-arg' for reverting
  ;; `Man-support-remote-systems'.
  (let ((result default-directory)
        (remote (if current-prefix-arg
                    (not Man-support-remote-systems)
                  Man-support-remote-systems)))

    ;; Use a local directory if remote isn't possible.
    (when (and (file-remote-p default-directory)
               (not (and remote
                         ;; TODO:: Test that remote processes are supported.
                         )))
      (setq result (expand-file-name "~/")))

    ;; Check, whether the directory is accessible.
    (if (file-accessible-directory-p result)
        result
      (expand-file-name (concat (file-remote-p result) "~/")))))

(defun Man-shell-file-name ()
  "Return a proper shell file name, respecting remote directories."
  (if (connection-local-p shell-file-name)
      (connection-local-value shell-file-name)
    "/bin/sh"))

(defun Man-header-file-path ()
  "Return the C header file search path that Man should use.
Normally, this is the value of the user option `Man-header-file-path',
but when the man page is formatted on a remote system (see
`Man-support-remote-systems'), this function tries to figure out the
list of directories where the remote system has the C header files."
  (let ((remote-id (file-remote-p default-directory)))
    (if (null remote-id)
        ;; The local case.
        (if (not (eq t Man-header-file-path))
            Man-header-file-path
          (require 'ffap)
          (defvar ffap-c-path)
          ffap-c-path)
      ;; The remote case.  Use connection-local variables.
      (mapcar
       (lambda (elt) (concat remote-id elt))
       (with-connection-local-variables
        (or (and (local-variable-p 'Man-header-file-path (current-buffer))
                 Man-header-file-path)
            (setq-connection-local
             Man-header-file-path
             (let ((arch (with-temp-buffer
                           (when (zerop (ignore-errors
                                          (process-file "gcc" nil '(t nil) nil
                                                        "-print-multiarch")))
                             (goto-char (point-min))
                             (buffer-substring (point) (line-end-position)))))
                   (base '("/usr/include" "/usr/local/include")))
               (if (zerop (length arch))
                   base
                 (append
                  base (list (expand-file-name arch "/usr/include"))))))))))))

(defun Man-init-defvars ()
  "Used for initializing variables based on display's color support.
This is necessary if one wants to dump man.el with Emacs."

  ;; Avoid possible error in call-process by using a directory that must exist.
  (let ((default-directory "/"))
    (setq Man-sed-script
	  (cond
	   (Man-fontify-manpage-flag
	    nil)
	   ((eq 0 (call-process Man-sed-command nil nil nil Man-sysv-sed-script))
	    Man-sysv-sed-script)
	   ((eq 0 (call-process Man-sed-command nil nil nil Man-berkeley-sed-script))
	    Man-berkeley-sed-script)
	   (t
	    nil))))

  (setq Man-filter-list
	;; Avoid trailing nil which confuses customize.
        (apply #'list
	 (cons
	  Man-sed-command
	  (if (eq system-type 'windows-nt)
	      ;; Windows needs ".." quoting, not '..'.
	      (list
	       "-e \"/Reformatting page.  Wait/d\""
	       "-e \"/Reformatting entry.  Wait/d\""
	       "-e \"/^[ \t][ \t]*-[ \t][0-9]*[ \t]-[ \t]*Formatted:.*[0-9]$/d\""
	       "-e \"/^[ \t]*Page[ \t][0-9]*.*(printed[ \t][0-9\\/]*)$/d\""
	       "-e \"/^Printed[ \t][0-9].*[0-9]$/d\""
	       "-e \"/^[ \t]*X[ \t]Version[ \t]1[01].*Release[ \t][0-9]/d\""
	       "-e \"/^[A-Za-z].*Last[ \t]change:/d\""
	       "-e \"/[ \t]*Copyright [0-9]* UNIX System Laboratories, Inc.$/d\""
	       "-e \"/^[ \t]*Rev\\..*Page [0-9][0-9]*$/d\"")
	    (list
	     (if Man-sed-script
		 (concat "-e '" Man-sed-script "'")
	       "")
	     "-e '/^[[:cntrl:]][[:cntrl:]]*$/d'"
	     "-e '/\e[789]/s///g'"
	     "-e '/Reformatting page.  Wait/d'"
	     "-e '/Reformatting entry.  Wait/d'"
	     "-e '/^[ \t]*Hewlett-Packard[ \t]Company[ \t]*-[ \t][0-9]*[ \t]-/d'"
	     "-e '/^[ \t]*Hewlett-Packard[ \t]*-[ \t][0-9]*[ \t]-.*$/d'"
	     "-e '/^[ \t][ \t]*-[ \t][0-9]*[ \t]-[ \t]*Formatted:.*[0-9]$/d'"
	     "-e '/^[ \t]*Page[ \t][0-9]*.*(printed[ \t][0-9\\/]*)$/d'"
	     "-e '/^Printed[ \t][0-9].*[0-9]$/d'"
	     "-e '/^[ \t]*X[ \t]Version[ \t]1[01].*Release[ \t][0-9]/d'"
	     "-e '/^[A-Za-z].*Last[ \t]change:/d'"
	     "-e '/^Sun[ \t]Release[ \t][0-9].*[0-9]$/d'"
	     "-e '/[ \t]*Copyright [0-9]* UNIX System Laboratories, Inc.$/d'"
	     "-e '/^[ \t]*Rev\\..*Page [0-9][0-9]*$/d'"
	     )))
	 ;; Windows doesn't support multi-line commands, so don't
	 ;; invoke Awk there.
	 (unless (eq system-type 'windows-nt)
	   (cons
	    Man-awk-command
	    (list
	     "'\n"
	     "BEGIN { blankline=0; anonblank=0; }\n"
	     "/^$/ { if (anonblank==0) next; }\n"
	     "{ anonblank=1; }\n"
	     "/^$/ { blankline++; next; }\n"
	     "{ if (blankline>0) { print \"\"; blankline=0; } print $0; }\n"
	     "'"
	     )))
	 (if (not Man-uses-untabify-flag)
	     ;; The outer list will be stripped off by apply.
	     (list (cons
		    Man-untabify-command
		    Man-untabify-command-args))
	   )))
)

(defsubst Man-make-page-mode-string ()
  "Formats part of the mode line for Man mode."
  (format "%s page %d of %d"
	  (or (nth 2 (nth (1- Man-current-page) Man-page-list))
	      "")
	  Man-current-page
	  (length Man-page-list)))

(defsubst Man-build-man-command ()
  "Builds the entire background manpage and cleaning command."
  (let ((command (concat manual-program " " Man-switches
                         (cond
                          ;; Already has %s
                          ((string-match "%s" manual-program) "")
                          ;; Stock MS-DOS shells cannot redirect stderr;
                          ;; `call-process' below sends it to /dev/null,
                          ;; so we don't need `2>' even with DOS shells
                          ;; which do support stderr redirection.
                          ((not (fboundp 'make-process)) " %s")
                          ((concat " %s 2>" null-device
                                   ;; Some MS-Windows ports of Groff
                                   ;; try to read stdin after exhausting
                                   ;; the command-line arguments; make
                                   ;; them exit if/when they do.
                                   (if (eq system-type 'windows-nt)
                                       (concat " <" null-device)))))))
	(flist Man-filter-list))
    (while (and flist (car flist))
      (let ((pcom (car (car flist)))
	    (pargs (cdr (car flist))))
	(setq command
	      (concat command " | " pcom " "
		      (mapconcat (lambda (phrase)
				   (if (not (stringp phrase))
				       (error "Malformed Man-filter-list"))
				   phrase)
				 pargs " ")))
        (setq flist (cdr flist))))
    command))


(defun Man-translate-cleanup (string)
  "Strip leading, trailing and middle spaces."
  (when (stringp string)
    ;;  Strip leading and trailing
    (if (string-match "^[ \t\f\r\n]*\\(.+[^ \t\f\r\n]\\)" string)
        (setq string (match-string 1 string)))
    ;; middle spaces
    (setq string (replace-regexp-in-string "[\t\r\n]" " " string))
    (setq string (replace-regexp-in-string "  +" " " string))
    string))

(defun Man-translate-references (ref)
  "Translates REF from \"chmod(2V)\" to \"2v chmod\" style.
Leave it as is if already in that style.  Possibly downcase and
translate the section (see the `Man-downcase-section-letters-flag'
and the `Man-section-translations-alist' variables)."
  (let ((name "")
        (section "")
        (slist Man-section-translations-alist))
    (setq ref (Man-translate-cleanup ref))
    (cond
     ;; "chmod(2V)" case ?
     ((string-match (concat "^" Man-reference-regexp "$") ref)
      (setq name (replace-regexp-in-string "[\n\t ]" "" (match-string 1 ref))
	    section (match-string 4 ref)))
     ;; "2v chmod" case ?
     ((string-match (concat "^\\(" Man-section-regexp
			    "\\) +\\(" Man-name-regexp "\\)$") ref)
      (setq name (match-string 2 ref)
	    section (match-string 1 ref))))
    (if (string= name "")
        ;; see Bug#66390
        (mapconcat #'identity
                   (mapcar #'shell-quote-argument
                           (split-string ref "\\s-+"))
                   " ")                 ; Return the reference as is
      (if Man-downcase-section-letters-flag
	  (setq section (downcase section)))
      (while slist
	(let ((s1 (car (car slist)))
	      (s2 (cdr (car slist))))
	  (setq slist (cdr slist))
	  (if Man-downcase-section-letters-flag
	      (setq s1 (downcase s1)))
	  (if (not (string= s1 section)) nil
	    (setq section (if Man-downcase-section-letters-flag
			      (downcase s2)
			    s2)
		  slist nil))))
      (concat Man-specified-section-option section " " name))))

(defun Man-support-local-filenames ()
  "Return non-nil if the man command supports local filenames.
Different man programs support this feature in different ways.
The default Debian man program (\"man-db\") has a `--local-file'
\(or `-l') option for this purpose.  The default Red Hat man
program has no such option, but interprets any name containing
a \"/\" as a local filename.  The function returns either `man-db',
`man', or nil."
  (if (eq Man-support-local-filenames 'auto-detect)
      (with-connection-local-variables
        (or (and (local-variable-p 'Man-support-local-filenames (current-buffer))
                 Man-support-local-filenames)
            (setq-connection-local
             Man-support-local-filenames
             (with-temp-buffer
               (let ((default-directory (Man-default-directory)))
                 (ignore-errors
                   (process-file manual-program nil t nil "--help")))
               (cond ((search-backward "--local-file" nil 'move)
                      'man-db)
                     ;; This feature seems to be present in at least
                     ;; ver 1.4f, which is about 20 years old.  I
                     ;; don't know if this version has an official
                     ;; name?
                     ((looking-at "^man, versione? [1-9]")
                      'man))))))
    Man-support-local-filenames))


;; ======================================================================
;; default man entry: get word near point

(defun Man-default-man-entry (&optional pos)
  "Guess default manual entry based on the text near position POS.
POS defaults to `point'."
  (let (word start column distance)
    (save-excursion
      (when pos (goto-char pos))
      (setq pos (point))
      ;; The default title is the nearest entry-like object before or
      ;; after POS.
      (if (and (skip-chars-backward " \ta-zA-Z0-9+")
	       (not (zerop (skip-chars-backward "(")))
	       ;; Try to handle the special case where POS is on a
	       ;; section number.
	       (looking-at
		(concat "([ \t]*\\(" Man-section-regexp "\\)[ \t]*)"))
	       ;; We skipped a valid section number backwards, look at
	       ;; preceding text.
	       (or (and (skip-chars-backward ",; \t")
			(not (zerop (skip-chars-backward "-a-zA-Z0-9._+:"))))
		   ;; Not a valid entry, move POS after closing paren.
		   (not (setq pos (match-end 0)))))
	  ;; We have a candidate, make `start' record its starting
	  ;; position.
	  (setq start (point))
	;; Otherwise look at char before POS.
	(goto-char pos)
	(if (not (zerop (skip-chars-backward "-a-zA-Z0-9._+:")))
	    ;; Our candidate is just before or around POS.
	    (setq start (point))
	  ;; Otherwise record the current column and look backwards.
	  (setq column (current-column))
	  (skip-chars-backward ",; \t")
	  ;; Record the distance traveled.
	  (setq distance (- column (current-column)))
	  (when (looking-back
		 (concat "([ \t]*\\(?:" Man-section-regexp "\\)[ \t]*)")
                 (line-beginning-position))
	    ;; Skip section number backwards.
	    (goto-char (match-beginning 0))
	    (skip-chars-backward " \t"))
	  (if (not (zerop (skip-chars-backward "-a-zA-Z0-9._+:")))
	      (progn
		;; We have a candidate before POS ...
		(setq start (point))
		(goto-char pos)
		(if (and (skip-chars-forward ",; \t")
			 (< (- (current-column) column) distance)
			 (looking-at "[-a-zA-Z0-9._+:]"))
		    ;; ... but the one after POS is better.
		    (setq start (point))
		  ;; ... and anything after POS is worse.
		  (goto-char start)))
	    ;; No candidate before POS.
	    (goto-char pos)
	    (skip-chars-forward ",; \t")
	    (setq start (point)))))
      ;; We have found a suitable starting point, try to skip at least
      ;; one character.
      (skip-chars-forward "-a-zA-Z0-9._+:")
      (setq word (buffer-substring-no-properties start (point)))
      ;; If there is a continuation at the end of line, check the
      ;; following line too, eg:
      ;;     see this-
      ;;     command-here(1)
      ;; Note: This code gets executed iff our entry is after POS.
      (when (looking-at
             (concat
              "‐?[ \t\r\n]+\\([-a-zA-Z0-9._+:]+\\)(" Man-section-regexp ")"))
        (let ((1st-part word))
          (setq word (concat word (match-string-no-properties 1)))
          ;; If they use -Tascii, we cannot know whether a hyphen at
          ;; EOL is or isn't part of the referenced manpage name.
          ;; Heuristics: if the part of the manpage before the hyphen
          ;; doesn't include a hyphen, we consider the hyphen to be
          ;; added by troff, and remove it.
          (or (not (eq (string-to-char (substring 1st-part -1)) ?-))
              (string-search "-" (substring 1st-part 0 -1))
              (setq word (string-replace "-" "" word))))
	;; Make sure the section number gets included by the code below.
	(goto-char (match-end 1)))
      (when (string-match "[-._‐]+$" word)
	(setq word (substring word 0 (match-beginning 0))))
      ;; The following was commented out since the preceding code
      ;; should not produce a leading "*" in the first place.
;;;       ;; If looking at something like *strcat(... , remove the '*'
;;;       (when (string-match "^*" word)
;;; 	(setq word (substring word 1)))
	(concat
	 word
	 (and (not (string-equal word ""))
	      ;; If looking at something like ioctl(2) or brc(1M),
	      ;; include the section number in the returned value.
	      (looking-at
	       (concat "[ \t]*([ \t]*\\(" Man-section-regexp "\\)[ \t]*)"))
	      (format "(%s)" (match-string-no-properties 1)))))))


;; ======================================================================
;; Top level command and background process sentinel

;; This alias was originally for compatibility with older versions.
;; Some users got used to having it, so we will not remove it.
;;;###autoload
(defalias 'manual-entry 'man)

(defvar Man-completion-cache nil
  ;; On my machine, "man -k" is so fast that a cache makes no sense,
  ;; but apparently that's not the case in all cases, so let's add a cache.
  "Cache of completion table of the form (PREFIX . TABLE).")

(defvar Man-man-k-use-anchor
  ;; man-db or man-1.*
  (memq system-type '(gnu gnu/linux gnu/kfreebsd))
  "If non-nil prepend ^ to the prefix passed to \"man -k\" for completion.
The value should be nil if \"man -k ^PREFIX\" may omit some man
pages whose names start with PREFIX.

Currently, the default value depends on `system-type' and is
non-nil where the standard man programs are known to behave
properly.  Setting the value to nil always gives correct results
but computing the list of completions may take a bit longer.")

(defun Man-parse-man-k ()
  "Parse \"man -k\" output and return the list of page names.

The current buffer should contain the output of a command of the
form \"man -k keyword\", which is traditionally also available with
apropos(1).

While POSIX man(1p) is a bit vague about what to expect here,
this function tries to parse some commonly used formats, which
can be described in the following informal way, with square brackets
indicating optional parts and whitespace being interpreted
somewhat loosely.

foo[, bar [, ...]] [other stuff] (sec) - description
foo(sec)[, bar(sec) [, ...]] [other stuff] - description"
  (goto-char (point-min))
  ;; See man-tests for data about which systems use which format (hopefully we
  ;; will be able to simplify the code if/when some of those formats aren't
  ;; used any more).
  (let (table)
    (while (search-forward-regexp "^\\([^ \t,\n]+\\)\\(.*?\\)\
\\(?:[ \t]\\(([^ \t,\n]+?)\\)\\)?\\(?:[ \t]+- ?\\(.*\\)\\)?$" nil t)
      (let ((section (match-string 3))
	    (description (match-string 4))
	    (bound (match-end 2)))
        (goto-char (match-end 1))
	(while
            (progn
              ;; The first regexp grouping may already match the section
              ;; tacked on to the name, which is ok since for the formats we
              ;; claim to support the third (non-shy) grouping does not
              ;; match in this case, i.e., section is nil.
              (push (propertize (concat (match-string 1) section)
                                'help-echo description)
                    table)
              (search-forward-regexp "\\=, *\\([^ \t,]+\\)" bound t)))))
    (nreverse table)))

(defvar Man-man-k-flags
  ;; It's not clear which man page will "always" be available, `man -k man'
  ;; seems like the safest choice, but `man -k apropos' seems almost as safe
  ;; and usually returns a much shorter output.
  (with-temp-buffer
    (with-demoted-errors "%S"
      (call-process manual-program nil t nil "-k" "apropos"))
    (let ((lines (count-lines (point-min) (point-max)))
          (completions (Man-parse-man-k)))
      (if (>= (length completions) lines)
          '("-k") ;; "-k" seems to return sane results: look no further!
        (erase-buffer)
        ;; Try "-k -l" (bug#73656).
        (with-demoted-errors "%S" (call-process manual-program nil t nil
                                                "-k" "-l" "apropos"))
        (let ((lines (count-lines (point-min) (point-max)))
              (completions (Man-parse-man-k)))
          (if (and (> lines 0) (>= (length completions) lines))
              '("-k" "-l") ;; "-k -l" seems to return sane results.
            '("-k"))))))
  "List of arguments to pass to get the expected \"man -k\" output.")

(defun Man-completion-table (string pred action)
  (cond
   ;; This ends up returning t for pretty much any string, and hence leads to
   ;; spurious "complete but not unique" messages.  And since `man' doesn't
   ;; require-match anyway, there's not point being clever.
   ;;((eq action 'lambda) (not (string-match "([^)]*\\'" string)))
   ((equal string "-k")
    ;; Let SPC (minibuffer-complete-word) insert the space.
    (complete-with-action action '("-k ") string pred))
   (t
    (let ((table (cdr Man-completion-cache))
          (section nil)
          (prefix string))
      (when (string-match "\\`\\([[:digit:]].*?\\) " string)
        (setq section (match-string 1 string))
        (setq prefix (substring string (match-end 0))))
      (unless (and Man-completion-cache
                   (string-prefix-p (car Man-completion-cache) prefix))
        (with-temp-buffer
          ;; In case inherited doesn't exist.
          (setq default-directory (Man-default-directory))
          ;; Actually for my `man' the arg is a regexp.
          ;; POSIX says it must be ERE and "man-db" seems to agree,
          ;; whereas under macOS it seems to be BRE-style and doesn't
          ;; accept backslashes at all.  Let's not bother to
          ;; quote anything.
          (with-environment-variables
              (("COLUMNS" "999"))       ; don't truncate long names
            ;; manual-program might not even exist.  And since it's
            ;; run differently in Man-getpage-in-background, an error
            ;; here may not necessarily mean that we'll also get an
            ;; error later.
            (when (eq 0
                      (ignore-errors
                        (apply
                         #'process-file
                         manual-program nil '(t nil) nil
                         ;; FIXME: When `process-file' runs on a remote hosts,
                         ;; `Man-man-k-flags' may be wrong.
                         `(,@Man-man-k-flags
                           ,(concat (when (or Man-man-k-use-anchor
                                                (string-equal prefix ""))
                                        "^")
                                      (if (string-equal prefix "")
                                          prefix
                                        ;; FIXME: shell-quote-argument
                                        ;; is not entirely
                                        ;; appropriate: we actually
                                        ;; need to quote ERE here.
                                        ;; But we don't have that, and
                                        ;; shell-quote-argument does
                                        ;; the job...
                                      (shell-quote-argument prefix)))))))
              (setq table (Man-parse-man-k)))))
	;; Cache the table for later reuse.
        (when table
          (setq Man-completion-cache (cons prefix table))))
      ;; The table may contain false positives since the match is made
      ;; by "man -k" not just on the manpage's name.
      (if section
          (let ((re (concat "(" (regexp-quote section) ")\\'")))
            (dolist (comp (prog1 table (setq table nil)))
              (if (string-match re comp)
                  (push (substring comp 0 (match-beginning 0)) table)))
            (completion-table-with-context (concat section " ") table
                                           prefix pred action))
        ;; If the current text looks like a possible section name,
        ;; then add a completion entry that just adds a space so SPC
        ;; can be used to insert a space.
        (if (string-match "\\`[[:digit:]]" string)
            (push (concat string " ") table))
        (let ((res (complete-with-action action table string pred)))
          ;; In case we're completing to a single name that exists in
          ;; several sections, the longest prefix will look like "foo(".
          (if (and (stringp res)
                   (string-match "([^(]*\\'" res)
                   ;; In case the paren was already in `prefix', don't
                   ;; remove it.
                   (> (match-beginning 0) (length prefix)))
              (substring res 0 (match-beginning 0))
            res)))))))

;;;###autoload
(defun man (man-args)
  "Get a Un*x manual page and put it in a buffer.
This command is the top-level command in the man package.
It runs a Un*x command to retrieve and clean a manpage in the
background and places the results in a `Man-mode' browsing
buffer.  The variable `Man-width' defines the number of columns in
formatted manual pages.  The buffer is displayed immediately.
The variable `Man-notify-method' defines how the buffer is displayed.
If a buffer already exists for this man page, it will be displayed
without running the man command.

For a manpage from a particular section, use either of the
following.  \"cat(1)\" is how cross-references appear and is
passed to man as \"1 cat\".

    cat(1)
    1 cat

To see manpages from all sections related to a subject, use an
\"all pages\" option (which might be \"-a\" if it's not the
default), then step through with `Man-next-manpage' (\\<Man-mode-map>\\[Man-next-manpage]) etc.
Add to `Man-switches' to make this option permanent.

    -a chmod

An explicit filename can be given too.  Use -l if it might
otherwise look like a page name.

    /my/file/name.1.gz
    -l somefile.1

An \"apropos\" query with -k gives a buffer of matching page
names or descriptions.  The pattern argument is usually an
\"grep -E\" style regexp.

    -k pattern

Note that in some cases you will need to use \\[quoted-insert] to quote the
SPC character in the above examples, because this command attempts
to auto-complete your input based on the installed manual pages.

If `default-directory' is remote, and `Man-support-remote-systems'
is non-nil, this command formats the man page on the remote system.
A prefix argument reverses the value of `Man-support-remote-systems'
for the current invocation."

  (interactive
   (list (let* ((default-entry (Man-default-man-entry))
		;; ignore case because that's friendly for bizarre
		;; caps things like the X11 function names and because
		;; "man" itself is case-insensitive on the command line
		;; so you're accustomed not to bother about the case
		;; ("man -k" is case-insensitive similarly, so the
		;; table has everything available to complete)
		(completion-ignore-case t)
		(input
                 (cl-flet ((read ()
                             (completing-read
                              (format-prompt "Manual entry"
                                             (and (not (equal default-entry ""))
                                                  default-entry))
                              #'Man-completion-table
                              nil nil nil 'Man-topic-history default-entry)))
                   (if Man-cache-completion-results-flag
                       (read)
                     (let ((Man-completion-cache)) (read))))))
	   (if (string= input "")
	       (error "No man args given")
	     input))))

  ;; Possibly translate the "subject(section)" syntax into the
  ;; "section subject" syntax and possibly downcase the section.
  (setq man-args (Man-translate-references man-args))

  (Man-getpage-in-background man-args))

;;;###autoload
(defun man-follow (man-args)
  "Get a Un*x manual page of the item under point and put it in a buffer."
  (interactive (list (Man-default-man-entry)) man-common)
  (if (or (not man-args)
	  (string= man-args ""))
      (error "No item under point")
    (man man-args)))

(defvar Man-columns nil)

(defun Man-columns ()
  (let ((width (cond
                ((and (integerp Man-width) (> Man-width 0))
                 Man-width)
                (Man-width
                 (let ((window (get-buffer-window nil t)))
                   (frame-width (and window (window-frame window)))))
                (t
                 (window-width (get-buffer-window nil t))))))
    (when (and (integerp Man-width-max)
               (> Man-width-max 0))
      (setq width (min width Man-width-max)))
    width))

(defmacro Man-start-calling (&rest body)
  "Start the man command in `body' after setting up the environment."
  (declare (debug t))
  `(let ((process-environment (copy-sequence process-environment))
	;; The following is so Awk script gets \n intact
	;; But don't prevent decoding of the outside.
	(coding-system-for-write 'raw-text-unix)
	;; We must decode the output by a coding system that the
	;; system's locale suggests in multibyte mode.
	(coding-system-for-read
         (or coding-system-for-read  ; allow overriding with "C-x RET c"
             Man-coding-system
             locale-coding-system))
	;; Avoid possible error by using a directory that always exists.
	(default-directory (Man-default-directory)))
    ;; Prevent any attempt to use display terminal fanciness.
    (setenv "TERM" "dumb")
    ;; In Debian Woody, at least, we get overlong lines under X
    ;; unless COLUMNS or MANWIDTH is set.  This isn't a problem on
    ;; a tty.  man(1) says:
    ;;        MANWIDTH
    ;;               If $MANWIDTH is set, its value is used as the line
    ;;               length for which manual pages should be formatted.
    ;;               If it is not set, manual pages will be formatted
    ;;               with a line length appropriate to the current
    ;;               terminal (using an ioctl(2) if available, the value
    ;;               of $COLUMNS, or falling back to 80 characters if
    ;;               neither is available).
    (when (or window-system
	      (not (or (getenv "MANWIDTH") (getenv "COLUMNS"))))
      ;; Since the page buffer is displayed beforehand,
      ;; we can select its window and get the window/frame width.
      (setq-local Man-columns (Man-columns))
      (setenv "COLUMNS" (number-to-string Man-columns)))
    ;; Since man-db 2.4.3-1, man writes plain text with no escape
    ;; sequences when stdout is not a tty.	In 2.5.0, the following
    ;; env-var was added to allow control of this (see Debian Bug#340673).
    (setenv "MAN_KEEP_FORMATTING" "1")
    ,@body))

(defun Man-getpage-in-background (topic)
  "Use TOPIC to build and fire off the manpage and cleaning command.
Return the buffer in which the manpage will appear."
  (let* ((default-directory (Man-default-directory))
         (man-args topic)
	 (bufname
          (if (file-remote-p default-directory)
              (format "*Man %s %s*" (file-remote-p default-directory) man-args)
            (format "*Man %s*" man-args)))
	 (buffer (get-buffer bufname)))
    (if buffer
	(Man-notify-when-ready buffer)
      (message "Invoking %s %s in the background" manual-program man-args)
      (setq buffer (generate-new-buffer bufname))
      (Man-notify-when-ready buffer)
      (with-current-buffer buffer
	(setq buffer-undo-list t)
	(setq Man-original-frame (selected-frame))
	(setq Man-arguments man-args)
	(Man-mode)
	(setq mode-line-process
	      (concat " " (propertize (if Man-fontify-manpage-flag
					  "[formatting...]"
					"[cleaning...]")
				      'face 'mode-line-emphasis)))
	(Man-start-calling
	 (if (and (fboundp 'make-process)
                  (not Man-prefer-synchronous-call))
	     (let ((proc (start-file-process
			  manual-program buffer
			  (Man-shell-file-name)
			  shell-command-switch
			  (format (Man-build-man-command) man-args))))
	       (set-process-sentinel proc 'Man-bgproc-sentinel)
	       (set-process-filter proc 'Man-bgproc-filter))
	   (let* ((inhibit-read-only t)
		  (exit-status
		   (process-file
                    (Man-shell-file-name) nil (list buffer nil) nil
		    shell-command-switch
		    (format (Man-build-man-command) man-args)))
		  (msg ""))
	     (or (and (numberp exit-status)
		      (= exit-status 0))
		 (and (numberp exit-status)
		      (setq msg
			    (format "exited abnormally with code %d"
				    exit-status)))
		 (setq msg exit-status))
	     (man--maybe-fontify-manpage)
	     (Man-bgproc-sentinel (cons buffer exit-status) msg))))))
    buffer))

(defun Man-update-manpage ()
  "Reformat current manpage by calling the man command again synchronously."
  (interactive nil man-common)
  (when (eq Man-arguments nil)
    ;;this shouldn't happen unless it is not in a Man buffer."
    (error "Man-arguments not initialized"))
  (let ((old-pos (point))
	(text (current-word))
	(old-size (buffer-size))
	(inhibit-read-only t)
	(buffer-read-only nil))
    (erase-buffer)
    (Man-start-calling
     (process-file
      (Man-shell-file-name) nil (list (current-buffer) nil) nil
      shell-command-switch
      (format (Man-build-man-command) Man-arguments)))
    (man--maybe-fontify-manpage)
    (goto-char old-pos)
    ;;restore the point, not strictly right.
    (unless (or (eq text nil) (= old-size (buffer-size)))
      (let ((case-fold-search nil))
	(if (> old-size (buffer-size))
	    (search-backward text nil t))
	(search-forward text nil t)))))

(defvar Man--window-state-change-timer nil)

(defun Man--window-state-change (window)
  (unless (integerp Man-width)
    (when (timerp Man--window-state-change-timer)
      (cancel-timer Man--window-state-change-timer))
    (setq Man--window-state-change-timer
          (run-with-idle-timer 1 nil #'Man-fit-to-window window))))

(defun Man-fit-to-window (window)
  "Adjust width of the buffer to fit columns into WINDOW boundaries."
  (when (window-live-p window)
    (with-current-buffer (window-buffer window)
      (when (and (derived-mode-p 'Man-mode)
                 Man-columns
                 (not (eq Man-columns (Man-columns))))
        (let ((proc (get-buffer-process (current-buffer))))
          (unless (and proc (not (eq (process-status proc) 'exit)))
            (Man-update-manpage)))))))

(defun Man-notify-when-ready (man-buffer)
  "Notify the user when MAN-BUFFER is ready.
See the variable `Man-notify-method' for the different notification behaviors."
  (let ((saved-frame (with-current-buffer man-buffer
		       Man-original-frame)))
    (pcase Man-notify-method
      ('newframe
       ;; Since we run asynchronously, perhaps while Emacs is waiting
       ;; for input, we must not leave a different buffer current.  We
       ;; can't rely on the editor command loop to reselect the
       ;; selected window's buffer.
       (save-excursion
         (let ((frame (make-frame Man-frame-parameters)))
           (set-window-buffer (frame-selected-window frame) man-buffer)
           (set-window-dedicated-p (frame-selected-window frame) t)
           (or (display-multi-frame-p frame)
               (select-frame frame)))))
      ('pushy
       (switch-to-buffer man-buffer))
      ('bully
       (and (frame-live-p saved-frame)
            (select-frame saved-frame))
       (pop-to-buffer man-buffer)
       (delete-other-windows))
      ('aggressive
       (and (frame-live-p saved-frame)
            (select-frame saved-frame))
       (pop-to-buffer man-buffer))
      ('friendly
       (and (frame-live-p saved-frame)
            (select-frame saved-frame))
       (display-buffer man-buffer 'not-this-window))
      ('thrifty
       (and (frame-live-p saved-frame)
            (select-frame saved-frame))
       (display-buffer man-buffer '(display-buffer-reuse-mode-window
                                    (mode . Man-mode))))
      ('polite
       (beep)
       (message "Manual buffer %s is ready" (buffer-name man-buffer)))
      ('quiet
       (message "Manual buffer %s is ready" (buffer-name man-buffer)))
      (_ ;; meek
       (message ""))
      )))

(defun Man-softhyphen-to-minus ()
  ;; \255 is SOFT HYPHEN in Latin-N.  Versions of Debian man, at
  ;; least, emit it even when not in a Latin-N locale.
  (unless (string-prefix-p "latin-" current-language-environment t)
    (goto-char (point-min))
    (while (search-forward "­" nil t) (replace-match "-"))))

(defun Man-fontify-manpage ()
  "Convert overstriking and underlining to the correct fonts.
Same for the ANSI bold and normal escape sequences."
  (interactive nil man-common)
  (goto-char (point-min))
  ;; Fontify ANSI escapes.
  (let ((ansi-color-apply-face-function #'ansi-color-apply-text-property-face)
	(ansi-color-basic-faces-vector Man-ansi-color-basic-faces-vector))
    (ansi-color-apply-on-region (point-min) (point-max)))
  ;; Other highlighting.
  (let ((buffer-undo-list t))
    (if (< (buffer-size) (position-bytes (point-max)))
	;; Multibyte characters exist.
	(progn
	  (goto-char (point-min))
	  (while (and (search-forward "__\b\b" nil t) (not (eobp)))
	    (delete-char -4)
            (put-text-property (point) (1+ (point))
                               'font-lock-face 'Man-underline))
	  (goto-char (point-min))
	  (while (search-forward "\b\b__" nil t)
	    (delete-char -4)
            (put-text-property (1- (point)) (point)
                               'font-lock-face 'Man-underline))))
    (goto-char (point-min))
    (while (and (re-search-forward "_\b\\([^_]\\)" nil t) (not (eobp)))
      (replace-match "\\1")
      (put-text-property (1- (point)) (point) 'font-lock-face 'Man-underline))
    (goto-char (point-min))
    (while (re-search-forward "\\([^_]\\)\b_" nil t)
      (replace-match "\\1")
      (put-text-property (1- (point)) (point) 'font-lock-face 'Man-underline))
    (goto-char (point-min))
    (while (re-search-forward "\\([^_]\\)\\(\b+\\1\\)+" nil t)
      (replace-match "\\1")
      (put-text-property (1- (point)) (point) 'font-lock-face 'Man-overstrike))
    ;; Special case for "__": is it an underlined underscore or a bold
    ;; underscore?  Look at the face after it to know.
    (goto-char (point-min))
    (while (search-forward "_\b_" nil t)
      (delete-char -2)
      (let ((face (get-text-property (point) 'font-lock-face)))
        (put-text-property (1- (point)) (point) 'font-lock-face face)))
    (goto-char (point-min))
    (while (re-search-forward "o\b\\+\\|\\+\bo" nil t)
      (replace-match "o")
      (put-text-property (1- (point)) (point) 'font-lock-face 'bold))
    (goto-char (point-min))
    (while (re-search-forward "[-|]\\(\b[-|]\\)+" nil t)
      (replace-match "+")
      (put-text-property (1- (point)) (point) 'font-lock-face 'bold))
    ;; When the header is longer than the manpage name, groff tries to
    ;; condense it to a shorter line interspersed with ^H.  Remove ^H with
    ;; their preceding chars (but don't put Man-overstrike).  (Bug#5566)
    (goto-char (point-min))
    (while (re-search-forward ".\b" nil t) (delete-char -2))
    (goto-char (point-min))
    ;; Try to recognize common forms of cross references.
    (Man-highlight-references)
    (Man-softhyphen-to-minus)
    (goto-char (point-min))
    (while (re-search-forward Man-heading-regexp nil t)
      (put-text-property (match-beginning 0)
			 (match-end 0)
			 'font-lock-face 'Man-overstrike))))

(defun Man-highlight-references (&optional xref-man-type)
  "Highlight the references on mouse-over.
References include items in the SEE ALSO section,
header file (#include <foo.h>), and files in FILES.
If optional argument XREF-MAN-TYPE is non-nil, it used as the
button type for items in SEE ALSO section.  If it is nil, the
default type, `Man-xref-man-page' is used for the buttons."
  ;; `Man-highlight-references' is used from woman.el, too.
  ;; woman.el doesn't set `Man-arguments'.
  (unless Man-arguments
    (setq Man-arguments ""))
  (if (string-match "-k " Man-arguments)
      (progn
	(Man-highlight-references0 nil Man-reference-regexp 1
                                   #'Man-default-man-entry
				   (or xref-man-type 'Man-xref-man-page))
	(Man-highlight-references0 nil Man-apropos-regexp 1
                                   #'Man-default-man-entry
				   (or xref-man-type 'Man-xref-man-page)))
    (Man-highlight-references0 Man-see-also-regexp Man-reference-regexp 1
                               #'Man-default-man-entry
			       (or xref-man-type 'Man-xref-man-page))
    (Man-highlight-references0 Man-synopsis-regexp Man-header-regexp 0 2
			       'Man-xref-header-file)
    (Man-highlight-references0 Man-files-regexp Man-normal-file-regexp 0 0
			       'Man-xref-normal-file)))

(defun Man-highlight-references0 (start-section regexp button-pos target type)
  ;; Based on `Man-build-references-alist'
  (when (or (null start-section) ;; Search regardless of sections.
            ;; Section header is in this chunk.
            (Man-find-section start-section))
    (let ((end (if start-section
		   (progn
		     (forward-line 1)
		     (back-to-indentation)
		     (save-excursion
		       (Man-next-section 1)
		       (point)))
		 (goto-char (point-min))
		 nil)))
      (while (re-search-forward regexp end t)
        (let ((b (match-beginning button-pos))
              (e (match-end button-pos))
              (match (match-string button-pos)))
          ;; Some lists of references end with ", and ...".  Chop the
          ;; "and" bit off before making a button.
          (when (string-match "\\`and +" match)
            (setq b (+ b (- (match-end 0) (match-beginning 0)))))
	  ;; An overlay button is preferable because the underlying text
	  ;; may have text property highlights (Bug#7881).
	  (make-button
	   b e
	   'type type
	   'Man-target-string (cond
			       ((numberp target)
			        (match-string target))
			       ((functionp target)
			        target)
			       (t nil))))))))

(defun Man-cleanup-manpage (&optional interactive)
  "Remove overstriking and underlining from the current buffer.
Normally skip any jobs that should have been done by the sed script,
but when called interactively, do those jobs even if the sed
script would have done them."
  (interactive "p" man-common)
  (if (or interactive (not Man-sed-script))
      (progn
	(goto-char (point-min))
	(while (search-forward "_\b" nil t) (delete-char -2))
	(goto-char (point-min))
	(while (search-forward "\b_" nil t) (delete-char -2))
	(goto-char (point-min))
	(while (re-search-forward "\\(.\\)\\(\b\\1\\)+" nil t)
	  (replace-match "\\1"))
	(goto-char (point-min))
	(while (re-search-forward "\e\\[[0-9]+m" nil t) (replace-match ""))
	(goto-char (point-min))
	(while (re-search-forward "o\b\\+\\|\\+\bo" nil t) (replace-match "o"))
	))
  (goto-char (point-min))
  (while (re-search-forward "[-|]\\(\b[-|]\\)+" nil t) (replace-match "+"))
  ;; When the header is longer than the manpage name, groff tries to
  ;; condense it to a shorter line interspersed with ^H.  Remove ^H with
  ;; their preceding chars (but don't put Man-overstrike).  (Bug#5566)
  (goto-char (point-min))
  (while (re-search-forward ".\b" nil t) (delete-char -2))
  (Man-softhyphen-to-minus))

(defun man--maybe-fontify-manpage ()
  (if Man-fontify-manpage-flag
      (Man-fontify-manpage)
    (Man-cleanup-manpage)))

(defun Man-bgproc-filter (process string)
  "Manpage background process filter.
When manpage command is run asynchronously, PROCESS is the process
object for the manpage command; when manpage command is run
synchronously, PROCESS is the name of the buffer where the manpage
command is run.  Second argument STRING is the entire string of output."
  (save-excursion
    (let ((Man-buffer (process-buffer process)))
      (if (not (buffer-live-p Man-buffer)) ;; deleted buffer
	  (set-process-buffer process nil)

	(with-current-buffer Man-buffer
	  (let ((inhibit-read-only t)
	        (beg (marker-position (process-mark process))))
	    (save-excursion
	      (goto-char beg)
	      (insert string)
	      (save-restriction
		(narrow-to-region
		 (save-excursion
		   (goto-char beg)
                   ;; Process whole sections (Bug#36927).
                   (Man-previous-section 1)
                   (point))
		 (point))
		(man--maybe-fontify-manpage))
	      (set-marker (process-mark process) (point-max)))))))))

(defun Man-bgproc-sentinel (process msg)
  "Manpage background process sentinel.
When manpage command is run asynchronously, PROCESS is the process
object for the manpage command; when manpage command is run
synchronously, PROCESS is a cons (BUFFER . EXIT-STATUS) of the buffer
where the manpage command has run and the exit status of the manpage
command.  Second argument MSG is the exit message of the manpage
command."
  (let ((asynchronous (processp process))
        Man-buffer process-status exit-status
	(delete-buff nil)
	message)

    (if asynchronous
        (setq Man-buffer     (process-buffer process)
              process-status (process-status process)
              exit-status    (process-exit-status process))
      (setq Man-buffer     (car process)
            process-status 'exit
            exit-status    (cdr process)))

    (if (not (buffer-live-p Man-buffer)) ;; deleted buffer
	(and asynchronous
	     (set-process-buffer process nil))

      (with-current-buffer Man-buffer
	(save-excursion
	  (let ((case-fold-search nil)
                (inhibit-read-only t))
	    (goto-char (point-min))
	    (cond ((or (looking-at "No \\(manual \\)*entry for")
		       (looking-at "[^\n]*: nothing appropriate$"))
		   (setq message (buffer-substring (point)
						   (progn
						     (end-of-line) (point)))
			 delete-buff t))

		  ;; "-k foo", successful exit, but no output (from man-db)
		  ;; ENHANCE-ME: share the check for -k with
		  ;; `Man-highlight-references'.  The \\s- bits here are
		  ;; meant to allow for multiple options with -k among them.
		  ((and (string-match "\\(\\`\\|\\s-\\)-k\\s-" Man-arguments)
			(eq process-status 'exit)
			(= exit-status 0)
			(= (point-min) (point-max)))
		   (setq message (format "%s: no matches" Man-arguments)
			 delete-buff t))

		  ((not (and (eq process-status 'exit)
			     (= exit-status 0)))
		   (or (zerop (length msg))
		       (progn
			 (setq message
			       (concat (buffer-name Man-buffer)
				       ": process "
				       (let ((eos (1- (length msg))))
					 (if (= (aref msg eos) ?\n)
					     (substring msg 0 eos) msg))))
			 (goto-char (point-max))
			 (insert (format "\nprocess %s" msg))))
		   ))
	    (unless delete-buff

	      (run-hooks 'Man-cooked-hook)

	      (Man-build-page-list)
	      (Man-strip-page-headers)
	      (Man-unindent)
	      (Man-goto-page 1 t)

	      (if (not Man-page-list)
		  (let ((args Man-arguments))
		    (setq delete-buff t)

                    ;; Entries hyphenated due to the window's width
                    ;; won't be found in the man database, so remove
                    ;; the hyphenation -- assuming Groff hyphenates
                    ;; either with hyphen-minus (ASCII 45, #x2d),
                    ;; hyphen (#x2010) or soft hyphen (#xad) -- and
                    ;; look again.
		    (if (string-match "[-‐­]" args)
			(let ((str (replace-match "" nil nil args)))
			  (Man-getpage-in-background str))
                      (setq message (format "Can't find the %s manpage"
                                            (Man-page-from-arguments args)))))

		(if Man-fontify-manpage-flag
		    (setq message (format "%s man page formatted"
			                  (Man-page-from-arguments Man-arguments)))
		  (setq message (format "%s man page cleaned up"
			                (Man-page-from-arguments Man-arguments))))
		(unless (and (processp process)
			     (not (eq (process-status process) 'exit)))
		  (setq mode-line-process nil))
		(set-buffer-modified-p nil))))))

      (when delete-buff
        (if (window-live-p (get-buffer-window Man-buffer t))
            (progn
              (quit-restore-window
               (get-buffer-window Man-buffer t) 'kill)
              ;; Ensure that we end up in the correct window.  Which is
              ;; only relevant in rather special cases and if we have
              ;; been called in an asynchronous fashion, see bug#38164.
              (and asynchronous
                   (let ((old-window (old-selected-window)))
                     (when (window-live-p old-window)
                       (select-window old-window)))))
          (kill-buffer Man-buffer)))

      (when message
        (message "%s" message)))))

(defun Man-page-from-arguments (args)
  ;; Skip arguments and only print the page name.
  (mapconcat
   #'identity
   (delete nil
	   (mapcar
	    (lambda (elem)
	      (and (not (string-match "^-" elem))
		   elem))
	    (split-string args " ")))
   " "))


;; ======================================================================
;; set up manual mode in buffer and build alists

(defvar bookmark-make-record-function)

(define-derived-mode man-common special-mode "Man Shared"
  "Parent mode for `Man-mode' like modes.
This mode is here to be inherited by modes that need to use
commands from `Man-mode'.  Used by `woman'.
(In itself, this mode currently does nothing.)"
  :interactive nil)

(define-derived-mode Man-mode man-common "Man"
  "A mode for browsing Un*x manual pages.

The following man commands are available in the buffer:
\\<Man-mode-map>
\\[man]       Prompt to retrieve a new manpage.
\\[Man-follow-manual-reference]       Retrieve reference in SEE ALSO section.
\\[Man-next-manpage]     Jump to next manpage in circular list.
\\[Man-previous-manpage]     Jump to previous manpage in circular list.
\\[Man-next-section]       Jump to next manpage section.
\\[Man-previous-section]       Jump to previous manpage section.
\\[Man-goto-section]       Go to a manpage section.
\\[Man-goto-see-also-section]       Jump to the SEE ALSO manpage section.
\\[quit-window]       Delete the manpage window, bury its buffer.
\\[Man-kill]       Delete the manpage window, kill its buffer.
\\[describe-mode]       Print this help text.

The following variables may be of some use:

`Man-notify-method'		What happens when manpage is ready to display.
`Man-downcase-section-letters-flag' Force section letters to lower case.
`Man-circular-pages-flag'	Treat multiple manpage list as circular.
`Man-section-translations-alist' List of section numbers and their Un*x equiv.
`Man-filter-list'		Background manpage filter command.
`Man-mode-map'			Keymap bindings for Man mode buffers.
`Man-mode-hook'			Normal hook run on entry to Man mode.
`Man-section-regexp'		Regexp describing manpage section letters.
`Man-heading-regexp'		Regexp describing section headers.
`Man-see-also-regexp'		Regexp for SEE ALSO section (or your equiv).
`Man-first-heading-regexp'	Regexp for first heading on a manpage.
`Man-reference-regexp'		Regexp matching a references in SEE ALSO.
`Man-switches'			Background `man' command switches.

The following key bindings are currently in effect in the buffer:
\\{Man-mode-map}"
  (setq buffer-auto-save-file-name nil
	mode-line-buffer-identification
	(list (default-value 'mode-line-buffer-identification)
	      " {" 'Man-page-mode-string "}")
	truncate-lines t)
  (buffer-disable-undo)
  (auto-fill-mode -1)
  (setq imenu-generic-expression (list (list nil Man-heading-regexp 0)))
  (imenu-add-to-menubar man-imenu-title)
  (setq-local outline-regexp Man-heading-regexp)
  (setq-local outline-level (lambda () 1))
  (setq-local bookmark-make-record-function
              #'Man-bookmark-make-record)
  (add-hook 'window-state-change-functions #'Man--window-state-change nil t))

(defun Man-build-section-list ()
  "Build the list of manpage sections."
  (setq Man--sections ())
  (goto-char (point-min))
  (let ((case-fold-search nil))
    (while (re-search-forward Man-heading-regexp nil t)
      (let ((section (match-string 1)))
        (unless (member section Man--sections)
          (push section Man--sections)))
      (forward-line)))
  (setq Man--sections (nreverse Man--sections)))

(defsubst Man-build-references-alist ()
  "Build the list of references (in the SEE ALSO section)."
  (setq Man--refpages nil)
  (save-excursion
    (if (Man-find-section Man-see-also-regexp)
	(let ((start (progn (forward-line 1) (point)))
	      (end (progn
		     (Man-next-section 1)
		     (point)))
	      hyphenated
	      (runningpoint -1))
	  (save-restriction
	    (narrow-to-region start end)
	    (goto-char (point-min))
	    (back-to-indentation)
	    (while (and (not (eobp)) (/= (point) runningpoint))
	      (setq runningpoint (point))
	      (if (re-search-forward Man-hyphenated-reference-regexp end t)
		  (let* ((word (match-string 0))
			 (len (1- (length word))))
		    (if hyphenated
			(setq word (concat hyphenated word)
			      hyphenated nil
			      ;; Update len, in case a reference spans
			      ;; more than two lines (paranoia).
			      len (1- (length word))))
		    (if (memq (aref word len) '(?- ?­))
			(setq hyphenated (substring word 0 len)))
		    (and (string-match Man-reference-regexp word)
                         (not (member word Man--refpages))
                         (push word Man--refpages))))
	      (skip-chars-forward " \t\n,"))))))
  (setq Man--refpages (nreverse Man--refpages)))

(defun Man-build-page-list ()
  "Build the list of separate manpages in the buffer."
  (setq Man-page-list nil)
  (let ((page-start (point-min))
	(page-end (point-max))
	(header ""))
    (goto-char page-start)
    (while (not (eobp))
      (setq header
	    (if (looking-at Man-page-header-regexp)
		(match-string 1)
	      nil))
      ;; Go past both the current and the next Man-first-heading-regexp
      (if (re-search-forward Man-first-heading-regexp nil 'move 2)
	  (let ((p (progn (beginning-of-line) (point))))
	    ;; We assume that the page header is delimited by blank
	    ;; lines and that it contains at most one blank line.  So
	    ;; if we back by three blank lines we will be sure to be
	    ;; before the page header but not before the possible
	    ;; previous page header.
	    (search-backward "\n\n" nil t 3)
	    (if (re-search-forward Man-page-header-regexp p 'move)
		(beginning-of-line))))
      (setq page-end (point))
      (setq Man-page-list (append Man-page-list
				  (list (list (copy-marker page-start)
					      (copy-marker page-end)
					      header))))
      (setq page-start page-end)
      )))

(defun Man-strip-page-headers ()
  "Strip all the page headers but the first from the manpage."
  (let ((inhibit-read-only t)
	(case-fold-search nil)
	(header ""))
    (dolist (page Man-page-list)
      (and (nth 2 page)
	   (goto-char (car page))
	   (re-search-forward Man-first-heading-regexp nil t)
	   (setq header (buffer-substring (car page) (match-beginning 0)))
	   ;; Since the awk script collapses all successive blank
	   ;; lines into one, and since we don't want to get rid of
	   ;; the fast awk script, one must choose between adding
	   ;; spare blank lines between pages when there were none and
	   ;; deleting blank lines at page boundaries when there were
	   ;; some.  We choose the first, so we comment the following
	   ;; line.
	   ;; (setq header (concat "\n" header)))
	   (while (search-forward header (nth 1 page) t)
	     (replace-match ""))))))

(defun Man-unindent ()
  "Delete the leading spaces that indent the manpage."
  (let ((inhibit-read-only t)
	(case-fold-search nil))
    (dolist (page Man-page-list)
      (let ((indent "")
	    (nindent 0))
	(narrow-to-region (car page) (car (cdr page)))
	(if Man-uses-untabify-flag
	    ;; The space characters inserted by `untabify' inherit
	    ;; sticky text properties, which is unnecessary and looks
	    ;; ugly with underlining (Bug#11408).
	    (let ((text-property-default-nonsticky
		   (cons '(face . t) text-property-default-nonsticky)))
	      (untabify (point-min) (point-max))))
	(if (catch 'unindent
	      (goto-char (point-min))
	      (if (not (re-search-forward Man-first-heading-regexp nil t))
		  (throw 'unindent nil))
	      (beginning-of-line)
	      (setq indent (buffer-substring (point)
					     (progn
					       (skip-chars-forward " ")
					       (point))))
	      (setq nindent (length indent))
	      (if (zerop nindent)
		  (throw 'unindent nil))
	      (setq indent (concat indent "\\|$"))
	      (goto-char (point-min))
	      (while (not (eobp))
		(if (looking-at indent)
		    (forward-line 1)
		  (throw 'unindent nil)))
	      (goto-char (point-min)))
	    (while (not (eobp))
	      (or (eolp)
		  (delete-char nindent))
	      (forward-line 1)))
	))))


;; ======================================================================
;; Man mode commands

(defun Man-next-section (n)
  "Move point to Nth next section (default 1)."
  (interactive "p" man-common)
  (let ((case-fold-search nil)
        (start (point)))
    (if (looking-at Man-heading-regexp)
	(forward-line 1))
    (if (re-search-forward Man-heading-regexp (point-max) t n)
	(beginning-of-line)
      (goto-char (point-max))
      ;; The last line doesn't belong to any section.
      (forward-line -1))
    ;; But don't move back from the starting point (can happen if `start'
    ;; is somewhere on the last line).
    (if (< (point) start) (goto-char start))))

(defun Man-previous-section (n)
  "Move point to Nth previous section (default 1)."
  (interactive "p" man-common)
  (let ((case-fold-search nil))
    (if (looking-at Man-heading-regexp)
	(forward-line -1))
    (if (re-search-backward Man-heading-regexp (point-min) t n)
	(beginning-of-line)
      (goto-char (point-min)))))

(defun Man-find-section (section)
  "Move point to SECTION if it exists, otherwise don't move point.
Returns t if section is found, nil otherwise."
  (let ((curpos (point))
	(case-fold-search nil))
    (goto-char (point-min))
    (if (re-search-forward (concat "^" section) (point-max) t)
	(progn (beginning-of-line) t)
      (goto-char curpos)
      nil)))

(defvar Man--last-section nil)

(defun Man-goto-section (section)
  "Move point to SECTION."
  (interactive
   (let* ((default (if (member Man--last-section Man--sections)
                       Man--last-section
                     (car Man--sections)))
          (completion-ignore-case t)
          (prompt (format-prompt "Go to section" default))
          (chosen (completing-read prompt Man--sections
                                   nil nil nil nil default)))
     (list chosen))
   man-common)
  (setq Man--last-section section)
  (unless (Man-find-section section)
    (error "Section %s not found" section)))


(defun Man-goto-see-also-section ()
  "Move point to the \"SEE ALSO\" section.
Actually the section moved to is described by `Man-see-also-regexp'."
  (interactive nil man-common)
  (if (not (Man-find-section Man-see-also-regexp))
      (error "%s" (concat "No " Man-see-also-regexp
		     " section found in the current manpage"))))

(defun Man-possibly-hyphenated-word ()
  "Return a possibly hyphenated word at point.
If the word starts at the first non-whitespace column, and the
previous line ends with a hyphen, return the last word on the previous
line instead.  Thus, if a reference to \"tcgetpgrp(3V)\" is hyphenated
as \"tcgetp-grp(3V)\", and point is at \"grp(3V)\", we return
\"tcgetp-\" instead of \"grp\"."
  (save-excursion
    (skip-syntax-backward "w()")
    (skip-chars-forward " \t")
    (let ((beg (point))
	  (word (current-word)))
      (when (eq beg (save-excursion
		      (back-to-indentation)
		      (point)))
	(end-of-line 0)
	(if (eq (char-before) ?-)
	    (setq word (current-word))))
      word)))

(defvar Man--last-refpage nil)

(defun Man-follow-manual-reference (reference)
  "Get one of the manpages referred to in the \"SEE ALSO\" section.
Specify which REFERENCE to use; default is based on word at point."
  (interactive
   (if (not Man--refpages)
       (error "There are no references in the current man page")
     (list
      (let* ((default (or
		       (car (all-completions
			     (let ((word
				    (or (Man-possibly-hyphenated-word)
					"")))
			       ;; strip a trailing '-':
			       (if (string-match "-$" word)
				   (substring word 0
					      (match-beginning 0))
				 word))
			     Man--refpages))
                       (if (member Man--last-refpage Man--refpages)
                           Man--last-refpage
                         (car Man--refpages))))
	     (defaults
              (mapcar #'substring-no-properties
                       (cons default Man--refpages)))
             (prompt (format-prompt "Refer to" default))
	     (chosen (completing-read prompt Man--refpages
				      nil nil nil nil defaults)))
        chosen)))
   man-common)
  (if (not Man--refpages)
      (error "Can't find any references in the current manpage")
    (setq Man--last-refpage reference)
    (Man-getpage-in-background
     (Man-translate-references reference))))

(defun Man-kill ()
  "Kill the buffer containing the manpage."
  (interactive nil man-common)
  (quit-window t))

(defun Man-goto-page (page &optional noerror)
  "Go to the manual page on page PAGE."
  (interactive
   (if (not Man-page-list)
       (error "Not a man page buffer")
     (if (= (length Man-page-list) 1)
	 (error "You're looking at the only manpage in the buffer")
       (list (read-minibuffer (format "Go to manpage [1-%d]: "
                                      (length Man-page-list))))))
    man-common)
  (if (and (not Man-page-list) (not noerror))
      (error "Not a man page buffer"))
  (when Man-page-list
    (if (or (< page 1)
	    (> page (length Man-page-list)))
	(user-error "No manpage %d found" page))
    (let* ((page-range (nth (1- page) Man-page-list))
	   (page-start (car page-range))
	   (page-end (car (cdr page-range))))
      (setq Man-current-page page
	    Man-page-mode-string (Man-make-page-mode-string))
      (widen)
      (goto-char page-start)
      (narrow-to-region page-start page-end)
      (Man-build-section-list)
      (Man-build-references-alist)
      (goto-char (point-min)))))


(defun Man-next-manpage ()
  "Find the next manpage entry in the buffer."
  (interactive nil man-common)
  (if (= (length Man-page-list) 1)
      (error "This is the only manpage in the buffer"))
  (if (< Man-current-page (length Man-page-list))
      (Man-goto-page (1+ Man-current-page))
    (if Man-circular-pages-flag
	(Man-goto-page 1)
      (error "You're looking at the last manpage in the buffer"))))

(defun Man-previous-manpage ()
  "Find the previous manpage entry in the buffer."
  (interactive nil man-common)
  (if (= (length Man-page-list) 1)
      (error "This is the only manpage in the buffer"))
  (if (> Man-current-page 1)
      (Man-goto-page (1- Man-current-page))
    (if Man-circular-pages-flag
	(Man-goto-page (length Man-page-list))
      (error "You're looking at the first manpage in the buffer"))))

;; Header file support
(defun man--find-header-files (file)
  (delq nil
        (mapcar (lambda (path)
                  (let ((complete-path (expand-file-name file path)))
                    (and (file-readable-p complete-path)
                         complete-path)))
                (Man-header-file-path))))

(defun Man-view-header-file (file)
  "View a header file specified by FILE from `Man-header-file-path'."
  (when-let* ((match (man--find-header-files file)))
    (view-file (car match))
    (car match)))

;;; Bookmark Man Support
(declare-function bookmark-make-record-default
                  "bookmark" (&optional no-file no-context posn))
(declare-function bookmark-prop-get "bookmark" (bookmark prop))
(declare-function bookmark-default-handler "bookmark" (bmk))
(declare-function bookmark-get-bookmark-record "bookmark" (bmk))

(defun Man-default-bookmark-title ()
  "Default bookmark name for Man or WoMan pages.
Uses `Man-name-local-regexp'."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward Man-name-local-regexp nil t)
      (skip-chars-forward "\n\t ")
      (buffer-substring-no-properties (point) (line-end-position)))))

(defun Man-bookmark-make-record ()
  "Make a bookmark entry for a Man buffer."
  `(,(Man-default-bookmark-title)
    ,@(bookmark-make-record-default 'no-file)
    (location . ,(concat "man " Man-arguments))
    (man-args . ,Man-arguments)
    (handler . Man-bookmark-jump)))

;;;###autoload
(defun Man-bookmark-jump (bookmark)
  "Default bookmark handler for Man buffers."
  (let* ((man-args (bookmark-prop-get bookmark 'man-args))
         ;; Let bookmark.el do the window handling.
         ;; This let-binding needs to be active during the call to both
         ;; Man-getpage-in-background and accept-process-output.
         (Man-notify-method 'meek)
         (buf (Man-getpage-in-background man-args))
         (proc (get-buffer-process buf)))
    (while (and proc (eq (process-status proc) 'run))
      (accept-process-output proc))
    (bookmark-default-handler
     `("" (buffer . ,buf) . ,(bookmark-get-bookmark-record bookmark)))))

(put 'Man-bookmark-jump 'bookmark-handler-type "Man")

;;; Mouse support
(defun Man-at-mouse (e)
  "Open man manual at point."
  (interactive "e")
  (save-excursion
    (mouse-set-point e)
    (man (Man-default-man-entry))))

;;;###autoload
(defun Man-context-menu (menu click)
  "Populate MENU with commands that open a man page at point."
  (save-excursion
    (mouse-set-point click)
    (when (save-excursion
            (skip-syntax-backward "^ ")
            (and (looking-at
                  "[[:space:]]*\\([[:alnum:]_-]+([[:alnum:]]+)\\)")
                 (match-string 1)))
      (define-key-after menu [man-separator] menu-bar-separator
        'middle-separator)
      (define-key-after menu [man-at-mouse]
        '(menu-item "Open man page" Man-at-mouse
                    :help "Open man page around mouse click")
        'man-separator)))
  menu)


;; Init the man package variables, if not already done.
(Man-init-defvars)

(provide 'man)

;;; man.el ends here
