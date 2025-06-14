;;; w32-win.el --- parse switches controlling interface with W32 window system -*- lexical-binding: t -*-

;; Copyright (C) 1993-1994, 2001-2025 Free Software Foundation, Inc.

;; Author: Kevin Gallo
;; Keywords: terminals

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

;; w32-win.el:  this file is loaded from ../lisp/startup.el when it recognizes
;; that W32 windows are to be used.  Command line switches are parsed and those
;; pertaining to W32 are processed and removed from the command line.  The
;; W32 display is opened and hooks are set for popping up the initial window.

;; startup.el will then examine startup files, and eventually call the hooks
;; which create the first window (s).

;;; Code:


;; These are the standard X switches from the Xt Initialize.c file of
;; Release 4.

;; Command line		Resource Manager string

;; +rv			*reverseVideo
;; +synchronous		*synchronous
;; -background		*background
;; -bd			*borderColor
;; -bg			*background
;; -bordercolor		*borderColor
;; -borderwidth		.borderWidth
;; -bw			.borderWidth
;; -display		.display
;; -fg			*foreground
;; -fn			*font
;; -font		*font
;; -foreground		*foreground
;; -geometry		.geometry
;; -i			.iconType
;; -itype		.iconType
;; -iconic		.iconic
;; -name		.name
;; -reverse		*reverseVideo
;; -rv			*reverseVideo
;; -selectionTimeout    .selectionTimeout
;; -synchronous		*synchronous
;; -xrm

;; An alist of X options and the function which handles them.  See
;; ../startup.el.

;; (if (not (eq window-system 'w32))
;;     (error "%s: Loading w32-win.el but not compiled for w32" invocation-name))

(eval-when-compile (require 'cl-lib))
(require 'frame)
(require 'mouse)
(require 'select)
(require 'w32-vars)

(declare-function x-select-font "w32font.c"
                  (&optional frame exclude-proportional))

(defvar w32-color-map) ;; defined in w32fns.c

(declare-function w32-send-sys-command "w32fns.c")
(declare-function set-message-beep "w32fns.c")

(declare-function cygwin-convert-file-name-from-windows "cygw32.c"
		  (path &optional absolute_p))

;; Conditional on new-fontset so bootstrapping works on non-GUI compiles
(if (fboundp 'new-fontset)
    (require 'fontset))

;; The following definition is used for debugging scroll bar events.
;(defun w32-handle-scroll-bar-event (event) (interactive "e") (princ event))

;; (defun w32-drag-n-drop-debug (event)
;;   "Print the drag-n-drop EVENT in a readable form."
;;   (interactive "e")
;;   (princ event))

(defun w32-handle-dropped-file (window file-name)
  (require 'dnd)
  (dnd-handle-multiple-urls
   window
   (list
    (w32-dropped-file-to-url file-name))
   'private))

(defun w32-dropped-file-to-url (file-name)
  (let ((f (if (eq system-type 'cygwin)
               (cygwin-convert-file-name-from-windows file-name t)
             (subst-char-in-string ?\\ ?/ file-name)))
        (coding (if (eq system-type 'windows-nt)
		    ;; Native w32 build pretends that its file names
		    ;; are encoded in UTF-8, and converts to the
		    ;; appropriate encoding internally.
		    'utf-8
		  (or file-name-coding-system
		      default-file-name-coding-system))))

    (setq file-name
          (mapconcat 'url-hexify-string
                     (split-string (encode-coding-string f coding)
                                   "/")
                     "/")))
  (concat
   (if (eq system-type 'cygwin)
       "file://"
     "file:")
   file-name))

(defun w32-drag-n-drop (event &optional new-frame)
  "Perform drag-n-drop action according to data in EVENT.
If EVENT is for one or more files, visit those files in corresponding
buffers, and switch to the buffer that visits the last dropped file.
If EVENT is for text, insert that text at point into the buffer
shown in the window that is the target of the drop; if that buffer is
read-only, add the dropped text to kill-ring.
If EVENT payload is nil, then this is a drag event.
If the optional argument NEW-FRAME is non-nil, perform the
drag-n-drop action in a newly-created frame using its selected-window
and that window's buffer."
  (interactive "e")
  (require 'dnd)
  ;; Make sure the drop target has positive co-ords
  ;; before setting the selected frame - otherwise it
  ;; won't work.  <skx@tardis.ed.ac.uk>
  (let* ((window (posn-window (event-start event)))
	 (coords (posn-x-y (event-start event)))
         (arg (car (cdr (cdr event))))
	 (x (car coords))
	 (y (cdr coords)))

    (if (and (> x 0) (> y 0) (window-live-p window))
        (set-frame-selected-window nil window))
    ;; Don't create new frame if we are just dragging
    (and arg new-frame
         (select-frame (make-frame)))
    (raise-frame)
    (setq window (selected-window))

    ;; arg (the payload of the event) is a string when the drop is
    ;; text, and a list of strings when the drop is one or more files.
    ;; It is nil if the event is a drag event.
    (if arg
        (save-excursion
          (if (stringp arg)
              (dnd-insert-text window 'copy arg)
            (dnd-handle-multiple-urls
             window
             (mapcar #'w32-dropped-file-to-url arg)
             'private)))
      (dnd-handle-movement (event-start event)))))

(defun w32-drag-n-drop-other-frame (event)
  "Edit the files listed in the drag-n-drop EVENT, in other frames.
May create new frames, or reuse existing ones.  The frame editing
the last file dropped is selected."
  (interactive "e")
  (w32-drag-n-drop event t))

;; Bind the drag-n-drop event.
(global-set-key [drag-n-drop] 'w32-drag-n-drop)
(global-set-key [C-drag-n-drop] 'w32-drag-n-drop-other-frame)

;; Keyboard layout/language change events
;; For now ignore language-change events; in the future
;; we should switch the Emacs Input Method to match the
;; new layout/language selected by the user.
(global-set-key [language-change] 'ignore)

;; Some Windows applications send the 'noname' (VK_NONAME) pseudo-key
;; to prevent Windows from sleeping.  We want to ignore these key
;; events, to avoid annoying users by ringing the bell and announcing
;; that the key is not bound.
(global-set-key [noname]   'ignore)
(global-set-key [C-noname] 'ignore)
(global-set-key [M-noname] 'ignore)


(defvar x-resource-name)


;;;; Function keys

 ;;; make f10 activate the real menubar rather than the mini-buffer menu
 ;;; navigation feature.
(defun w32-menu-bar-open (&optional frame)
   "Start key navigation of the menu bar in FRAME.

This initially activates the first menu-bar item, and you can then navigate
with the arrow keys, select a menu entry with the Return key or cancel with
one or two Escape keypresses.  (Two Escape keypresses are needed when a
menu was already dropped down by pressing Return.)

If FRAME has no menu bar, this function does nothing.

If FRAME is nil or not given, use the selected frame.
If FRAME does not have the menu bar enabled, display a text menu using
`tmm-menubar'."
   (interactive "i")
   (require 'menu-bar)
   (if menu-bar-mode
       (w32-send-sys-command ?\xf100 frame)
     (with-selected-frame (or frame (selected-frame))
       (tmm-menubar))))


;; W32 systems have different fonts than commonly found on X, so
;; we define our own standard fontset here.
(defvar w32-standard-fontset-spec
 "-*-Courier New-normal-r-*-*-13-*-*-*-c-*-fontset-standard"
 "String of fontset spec of the standard fontset.
This defines a fontset consisting of the Courier New variations for
European languages which are distributed with Windows as
\"Multilanguage Support\".

See the documentation of `create-fontset-from-fontset-spec' for the format.")

(defun w32-win-suspend-error ()
  "Report an error when a suspend is attempted."
  (error "Suspending an Emacs running under W32 makes no sense"))

;;; multi-tty support
(defvar w32-initialized nil
  "Non-nil if the w32 window system has been initialized.")

(declare-function x-open-connection "w32fns.c"
                  (display &optional xrm-string must-succeed))
(declare-function create-default-fontset "fontset" ())
(declare-function create-fontset-from-fontset-spec "fontset"
                  (fontset-spec &optional style-variant noerror))
(declare-function create-fontset-from-x-resource "fontset" ())
(declare-function x-get-resource "frame.c"
                  (attribute class &optional component subclass))
(declare-function x-handle-args "common-win" (args))
(declare-function x-parse-geometry "frame.c" (string))
(defvar x-command-line-resources)

(cl-defmethod window-system-initialization (&context (window-system w32)
                                            &optional _display)
  "Initialize Emacs for W32 GUI frames."
  (cl-assert (not w32-initialized))

  ;; Do the actual Windows setup here; the above code just defines
  ;; functions and variables that we use now.

  (setq command-line-args (x-handle-args command-line-args))

  ;; Make sure we have a valid resource name.
  (or (stringp x-resource-name)
      (setq x-resource-name
            ;; Change any . or * characters in x-resource-name to hyphens,
            ;; so as not to choke when we use it in X resource queries.
            (replace-regexp-in-string "[.*]" "-" invocation-name)))

  (x-open-connection "w32" x-command-line-resources
                     ;; Exit with a fatal error if this fails and we
                     ;; are the initial display
                     (eq initial-window-system 'w32))

  ;; Create the default fontset.
  (create-default-fontset)
  ;; Create the standard fontset.
  (condition-case err
      (create-fontset-from-fontset-spec w32-standard-fontset-spec t)
    (error (display-warning
	    'initialization
	    (format "Creation of the standard fontset failed: %s" err)
	    :error)))
  ;; Create fontset specified in X resources "Fontset-N" (N is 0, 1,...).
  (create-fontset-from-x-resource)

  ;; Apply a geometry resource to the initial frame.  Put it at the end
  ;; of the alist, so that anything specified on the command line takes
  ;; precedence.
  (let* ((res-geometry (x-get-resource "geometry" "Geometry"))
         parsed)
    (if res-geometry
        (progn
          (setq parsed (x-parse-geometry res-geometry))
          ;; If the resource specifies a position,
          ;; call the position and size "user-specified".
          (if (or (assq 'top parsed) (assq 'left parsed))
              (setq parsed (cons '(user-position . t)
                                 (cons '(user-size . t) parsed))))
          ;; All geometry parms apply to the initial frame.
          (setq initial-frame-alist (append initial-frame-alist parsed))
          ;; The size parms apply to all frames.
          (if (and (assq 'height parsed)
                   (not (assq 'height default-frame-alist)))
              (setq default-frame-alist
                    (cons (cons 'height (cdr (assq 'height parsed)))
                          default-frame-alist))
          (if (and (assq 'width parsed)
                   (not (assq 'width default-frame-alist)))
              (setq default-frame-alist
                    (cons (cons 'width (cdr (assq 'width parsed)))
                          default-frame-alist)))))))

  ;; Check the reverseVideo resource.
  (let ((case-fold-search t))
    (let ((rv (x-get-resource "reverseVideo" "ReverseVideo")))
      (if (and rv (string-match "^\\(true\\|yes\\|on\\)$" rv))
          (setq default-frame-alist
                (cons '(reverse . t) default-frame-alist)))))

  ;; Don't let Emacs suspend under Windows.
  (add-hook 'suspend-hook #'w32-win-suspend-error)

  ;; Turn off window-splitting optimization; w32 is usually fast enough
  ;; that this is only annoying.
  (setq split-window-keep-point t)

  (when menu-bar-mode
    (require 'menu-bar)
    ;; W32 expects the menu bar cut and paste commands to use the clipboard.
    (menu-bar-enable-clipboard))

  ;; Don't show the frame name; that's redundant.
  (setq-default mode-line-frame-identification "  ")

  ;; Set to a system sound if you want a fancy bell.
  (set-message-beep 'ok)
  (x-apply-session-resources)
  (setq w32-initialized t))

(add-to-list 'display-format-alist '("\\`w32\\'" . w32))
(cl-defmethod handle-args-function (args &context (window-system w32))
  (x-handle-args args))

(cl-defmethod frame-creation-function (params &context (window-system w32))
  (x-create-frame-with-faces params))

;;;; Selections

(declare-function w32-set-clipboard-data "w32select.c"
		  (string &optional ignored))
(declare-function w32-get-clipboard-data "w32select.c"
                  (&optional ignored))
(declare-function w32-selection-exists-p "w32select.c"
                  (&optional selection terminal))
(declare-function w32-selection-targets "w32select.c"
                  (&optional selection terminal))

;;; Fix interface to (X-specific) mouse.el
(defun w32--set-selection (type value)
  (if (eq type 'CLIPBOARD)
      (w32-set-clipboard-data (string-replace "\0" "\\0" value))
    (put 'x-selections (or type 'PRIMARY) value)))

(defvar w32--selection-target-translations
  '((PNG . image/png)
    (DIBV5 . image/png)
    (HTML\ Format . text/html)))

(defun w32--translate-selection-target (target)
  (let ((xlat (assoc target w32--selection-target-translations)))
    (if xlat
        (cdr xlat)
      target)))

(defun w32--translate-reverse-selection-target (target)
  (append
   (mapcar #'car
           (seq-filter
            (lambda (x)
              (eq target
                  (w32--translate-selection-target (car x))))
            w32--selection-target-translations))
   (list target)))

(defvar w32--textual-mime-types
  '("application/xml"
    "application/json"
    "application/yaml"
    "application/json-seq"
    "\\`text/"
    "\\+xml\\'"
    "\\+json\\'"
    "\\+yaml\\'"
    "\\+json-seq\\'"))

(defun w32--mime-type-textual-p (mime-type)
  "Returns t if MIME-TYPE, a symbol, names a textual MIME type.

This function is intended to classify clipboard data.  All MIME subtypes
of text/ are considered textual.  Also those with suffixes +xml, +json,
+yaml, +json-seq.  And application/xml, application/json,
application/yaml, application/json-seq.

This classification is not exhaustive.  Some MIME types not listed may
also be textual."
  (string-match-p
   (mapconcat #'identity w32--textual-mime-types "\\|")
        (symbol-name mime-type)))

(declare-function w32--get-clipboard-data-media "w32select.c")

(defun w32--get-selection (&optional type data-type)
  (cond ((and (eq type 'CLIPBOARD)
              (memq data-type '(STRING UTF8_STRING TEXT)))
         (with-demoted-errors "w32-get-clipboard-data:%S"
           (w32-get-clipboard-data)))
        ((eq data-type 'TARGETS)
         (if (eq type 'CLIPBOARD)
             (vconcat
              (delete-dups
               (seq-map #'w32--translate-selection-target
                        (w32-selection-targets type))))
           (if (get 'x-selections (or type 'PRIMARY)) '[STRING])))
        ((eq type 'CLIPBOARD)
         (let ((tmp-file (make-temp-file "emacs-clipboard"))
               (is-textual (w32--mime-type-textual-p data-type)))
           (unwind-protect
               (let* ((data-types (w32--translate-reverse-selection-target data-type))
                      (data (w32--get-clipboard-data-media data-types tmp-file is-textual)))
                 (cond
                  ;; data is in the file
                  ((eq data t)
                   (with-temp-buffer
                     (set-buffer-multibyte nil)
                     (insert-file-contents-literally tmp-file)
                     (buffer-string)))
                  ;; data is in data var
                  ((stringp data) data)
                  ;; No data
                  (t nil)))
             (delete-file tmp-file))))
        (t (get 'x-selections (or type 'PRIMARY)))))

(defun w32--selection-owner-p (selection)
  (and (memq selection '(nil PRIMARY SECONDARY))
       (get 'x-selections (or selection 'PRIMARY))))

(cl-defmethod gui-backend-set-selection (type value
                                         &context (window-system w32))
  (w32--set-selection type value))

(cl-defmethod gui-backend-get-selection (type data-type
                                         &context (window-system w32))
  (w32--get-selection type data-type))

(cl-defmethod gui-backend-selection-owner-p (selection
                                             &context (window-system w32))
  (w32--selection-owner-p selection))

(cl-defmethod gui-backend-selection-exists-p (selection
                                              &context (window-system w32))
  (w32-selection-exists-p selection))

;; The "Windows" keys on newer keyboards bring up the Start menu
;; whether you want it or not - make Emacs ignore these keystrokes
;; rather than beep.
(global-set-key [lwindow] 'ignore)
(global-set-key [rwindow] 'ignore)

(declare-function x-server-version "w32fns.c" (&optional terminal))

(defun w32-version ()
  "Return the MS-Windows version numbers.
The value is a list of three integers: the major and minor version
numbers, and the build number."
  (x-server-version))

(defun w32-using-nt ()
  "Return non-nil if running on a Windows NT descendant.
That includes all Windows systems except for 9X/Me."
  (getenv "SystemRoot"))

;; The value of the following variable was calculated using the table in
;; https://docs.microsoft.com/windows/desktop/Intl/unicode-subset-bitfields,
;; by looking for Unicode subranges for which no USB bits are defined.
(defconst w32-no-usb-subranges
  '((#x000800 . #x0008ff)
    (#x0018b0 . #x0018ff)
    (#x001a20 . #x001aff)
    (#x001bc0 . #x001bff)
    (#x001c80 . #x001cff)
    (#x002fe0 . #x002fef)
    (#x00a4d0 . #x00a4ff)
    (#x00a6a0 . #x00a6ff)
    (#x00a830 . #x00a83f)
    (#x00a8e0 . #x00a8ff)
    (#x00a960 . #x00a9ff)
    (#x00aa60 . #x00abff)
    (#x00d7b0 . #x00d7ff)
    (#x010200 . #x01027f)
    (#x0102e0 . #x0102ff)
    (#x010350 . #x01037f)
    (#x0103e0 . #x0103ff)
    (#x0104b0 . #x0107ff)
    (#x010840 . #x0108ff)
    (#x010940 . #x0109ff)
    (#x010a60 . #x011fff)
    (#x012480 . #x01cfff)
    (#x01d250 . #x01d2ff)
    (#x01d380 . #x01d3ff)
    (#x01d800 . #x01efff)
    (#x01f0a0 . #x01ffff)
    (#x02a6e0 . #x02f7ff)
    (#x02fa20 . #x0dffff)
    (#x0e0080 . #x0e00ff)
    (#x0e01f0 . #x0fefff))
  "List of Unicode subranges whose support cannot be announced by a font.
The FONTSIGNATURE structure reported by MS-Windows for a font
includes 123 Unicode Subset bits (USBs) to identify subranges of
the Unicode codepoint space supported by the font.  Since the
number of bits is fixed, not every Unicode block can have a
corresponding USB bit; fonts that support characters from blocks
that have no USBs cannot communicate their support to Emacs,
unless the font is opened and physically tested for glyphs for
characters from these blocks.")

(defun w32--filter-USB-scripts ()
  "Filter USB scripts out of `script-representative-chars'."
  (let (val)
    (dolist (elt script-representative-chars)
      (let ((subranges w32-no-usb-subranges)
            (chars (append (cdr elt) nil)) ; handle vectors as well
            ch found subrange)
        (while (and (consp chars) (not found))
          (setq ch (car chars)
                chars (cdr chars))
          (while (and (consp subranges) (not found))
            (setq subrange (car subranges)
                  subranges (cdr subranges))
            (when (and (>= ch (car subrange)) (<= ch (cdr subrange)))
              (setq found t)
              (push elt val))))))
    (nreverse val)))

(defvar w32-non-USB-fonts nil
  "Alist of script symbols and corresponding fonts.
Each element of the alist has the form (SCRIPT FONTS...), where
SCRIPT is a symbol of a script and FONTS are one or more fonts installed
on the system that can display SCRIPT's characters.  FONTS are
specified as symbols.
Only scripts that have no corresponding Unicode Subset Bits (USBs) can
be found in this alist.
This alist is used by w32font.c when it looks for fonts that can display
characters from scripts for which no USBs are defined.")

(declare-function x-list-fonts "xfaces.c"
                  (pattern &optional face frame maximum width))

(defun w32-find-non-USB-fonts (&optional frame size)
  "Compute the value of `w32-non-USB-fonts' for specified SIZE and FRAME.
FRAME defaults to the selected frame.
SIZE is the required font size and defaults to the nominal size of the
default font on FRAME, or its best approximation."
  (let* ((inhibit-compacting-font-caches t)
         (all-fonts
          (delete-dups
           (x-list-fonts "-*-*-medium-r-normal-*-*-*-*-*-*-iso10646-1"
                         'default frame)))
         val)
    (mapc (lambda (script-desc)
            (let* ((script (car script-desc))
                   (script-chars (vconcat (cdr script-desc)))
                   (nchars (length script-chars))
                   (fntlist all-fonts)
                   (entry (list script))
                   fspec ffont font-obj glyphs idx)
              ;; For each font in FNTLIST, determine whether it
              ;; supports the representative character(s) of any
              ;; scripts that have no USBs defined for it.
              (dolist (fnt fntlist)
                (setq fspec (ignore-errors (font-spec :name fnt)))
                (if fspec
                    (setq ffont (find-font fspec frame)))
                (when ffont
                  (setq font-obj
                        (open-font ffont size frame))
                  ;; Ignore fonts for which open-font returns nil:
                  ;; they are buggy fonts that we cannot use anyway.
                  (setq glyphs
                        (if font-obj
                            (font-get-glyphs font-obj
                                             0 nchars script-chars)
                          '[nil]))
                  ;; Does this font support ALL of the script's
                  ;; representative characters?  Note that, when the
                  ;; representative characters are specified as a
                  ;; vector, this is a more stringent test than font
                  ;; selection does, because supporting _any_
                  ;; character from the vector is enough.
                  (setq idx 0)
                  (while (and (< idx nchars) (not (null (aref glyphs idx))))
                    (setq idx (1+ idx)))
                  (if (= idx nchars)
                      ;; It does; add this font to the script's entry in alist.
                      (let ((font-family (font-get font-obj :family)))
                        ;; Unifont is an ugly font, and it is already
                        ;; present in the default fontset.
                        (unless (string= (downcase (symbol-name font-family))
                                         "unifont")
                          (push font-family entry))))))
              (if (> (length entry) 1)
                  (push (nreverse entry) val))))
          (w32--filter-USB-scripts))
    ;; We've opened a lot of fonts, so clear the font caches to free
    ;; some memory.
    (clear-font-cache)
    (and val (setq w32-non-USB-fonts val))))

(provide 'w32-win)
(provide 'term/w32-win)

;;; w32-win.el ends here
