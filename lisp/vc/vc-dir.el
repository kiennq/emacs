;;; vc-dir.el --- Directory status display under VC  -*- lexical-binding: t -*-

;; Copyright (C) 2007-2025 Free Software Foundation, Inc.

;; Author: Dan Nicolaescu <dann@ics.uci.edu>
;; Keywords: vc tools
;; Package: vc

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

;;; Credits:

;; The original VC directory status implementation was based on dired.
;; This implementation was inspired by PCL-CVS.
;; Many people contributed comments, ideas and code to this
;; implementation.  These include:
;;
;;   Alexandre Julliard  <julliard@winehq.org>
;;   Stefan Monnier  <monnier@iro.umontreal.ca>
;;   Tom Tromey  <tromey@redhat.com>

;;; Commentary:
;;

;;; Todo:  see vc.el.

(require 'vc-hooks)
(require 'vc)
(require 'tool-bar)
(require 'ewoc)
(require 'seq)

;;; Code:
(require 'cl-lib)

(declare-function fileloop-continue "fileloop")

(defcustom vc-dir-mode-hook nil
  "Normal hook run by `vc-dir-mode'.
See `run-hooks'."
  :type 'hook
  :group 'vc)

(defface vc-dir-header '((t :inherit font-lock-type-face))
  "Face for headers in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-header-value '((t :inherit font-lock-variable-name-face))
  "Face for header values in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-directory '((t :inherit font-lock-comment-delimiter-face))
  "Face for directories in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-file '((t :inherit font-lock-function-name-face))
  "Face for files in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-mark-indicator '((t :inherit font-lock-type-face))
  "Face for mark indicators in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-status-warning '((t :inherit font-lock-warning-face))
  "Face for warning status in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-status-edited '((t :inherit font-lock-variable-name-face))
  "Face for edited status in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-status-up-to-date '((t :inherit font-lock-builtin-face))
  "Face for up-to-date status in VC-dir buffers."
  :group 'vc
  :version "28.1")

(defface vc-dir-status-ignored '((t :inherit shadow))
  "Face for ignored or empty values in VC-dir buffers."
  :group 'vc
  :version "28.1")

;; Used to store information for the files displayed in the directory buffer.
;; Each item displayed corresponds to one of these defstructs.
(cl-defstruct (vc-dir-fileinfo
            (:copier nil)
            (:type list)            ;So we can use `member' on lists of FIs.
            (:constructor
             ;; We could define it as an alias for `list'.
	     vc-dir-create-fileinfo (name state &optional extra marked directory))
            (:conc-name vc-dir-fileinfo->))
  name                                  ;Keep it as first, for `member'.
  state
  ;; For storing backend specific information.
  extra
  marked
  ;; To keep track of not updated files during a global refresh
  needs-update
  ;; To distinguish files and directories.
  directory)

(defvar vc-ewoc nil)

(defvar vc-dir-process-buffer nil
  "The buffer used for the asynchronous call that computes status.")

(defvar vc-dir-backend nil
  "The backend used by the current *vc-dir* buffer.")

(defcustom vc-dir-allow-mass-mark-changes 'ask
  "If non-nil, VC-Dir commands may mark or unmark many items at once.

When a directory in VC-Dir is marked, then for most VCS, this means that
all files within it are implicitly marked as well.
For consistency, the mark and unmark commands (principally \\<vc-dir-mode-map>\\[vc-dir-mark] and \\[vc-dir-unmark]) will
not explicitly mark or unmark entries if doing so would result in a
situation where both a directory and a file or directory within it are
both marked.

With the default value of this variable, `ask', if you attempt to mark
or unmark a particular item and doing so consistent with these
restrictions would require other items to be marked or unmarked too,
Emacs will prompt you to confirm that you do mean for the other items to
be marked or unmarked.

If this variable is nil, the commands will refuse to do anything if they
would need to mark or unmark other entries too.
If this variable is any other non-nil value, the commands will always
proceed to mark and unmark other entries, without asking.

There is one operation where marking or unmarking other entries in order
to mark or unmark the entry at point is unlikely to be surprising:
when you use \\[vc-dir-mark] on a directory which already has marked items within it.
In this case, the subitems are unmarked regardless of the value of this
option."
  :type '(choice (const :tag "Don't allow" nil)
                 (const :tag "Prompt to allow" ask)
                 (const :tag "Allow without prompting" t))
  :group 'vc
  :version "31.1")

(defcustom vc-dir-hide-up-to-date-on-revert nil
  "If non-nil, \\<vc-dir-mode-map>\\[revert-buffer] in VC-Dir buffers also does \\[vc-dir-hide-up-to-date].
That is, refreshing the VC-Dir buffer also hides `up-to-date' and
`ignored' items."
  :type 'boolean
  :group 'vc
  :version "31.1")

(defcustom vc-dir-save-some-buffers-on-revert nil
  "If non-nil, first offer to save relevant buffers when refreshing VC-Dir."
  :type 'boolean
  :group 'vc
  :version "31.1")

(defun vc-dir-move-to-goal-column ()
  ;; Used to keep the cursor on the file name column.
  (beginning-of-line)
  (unless (eolp)
    ;; Must be in sync with vc-default-dir-printer.
    (forward-char 25)))

(defun vc-dir-prepare-status-buffer (bname dir backend &optional create-new)
  "Find a buffer named BNAME showing DIR, or create a new one."
  (setq dir (file-name-as-directory (expand-file-name dir)))
  (let* ;; Look for another buffer name BNAME visiting the same directory.
      ((buf (save-excursion
              (unless create-new
                (cl-dolist (buffer vc-dir-buffers)
                  (when (buffer-live-p buffer)
                    (set-buffer buffer)
                    (when (and (derived-mode-p 'vc-dir-mode)
                               (eq vc-dir-backend backend)
                               (string= default-directory dir))
                      (cl-return buffer))))))))
    (or buf
        ;; Create a new buffer named BNAME.
	;; We pass a filename to create-file-buffer because it is what
	;; the function expects, and also what uniquify needs (if active)
        (with-current-buffer (create-file-buffer (expand-file-name bname dir))
          (setq default-directory dir)
          (vc-setup-buffer (current-buffer))
          ;; Reset the vc-parent-buffer-name so that it does not appear
          ;; in the mode-line.
          (setq vc-parent-buffer-name nil)
          (current-buffer)))))

(defvar vc-dir-menu-map
  (let ((map (make-sparse-keymap "VC-Dir")))
    (define-key map [quit]
      '(menu-item "Quit" quit-window
		  :help "Quit"))
    (define-key map [kill]
      '(menu-item "Kill Update Command" vc-dir-kill-dir-status-process
		  :enable (vc-dir-busy)
		  :help "Kill the command that updates the directory buffer"))
    (define-key map [refresh]
      '(menu-item "Refresh" revert-buffer
		  :enable (not (vc-dir-busy))
		  :help "Refresh the contents of the directory buffer"))
    (define-key map [remup]
      '(menu-item "Hide Up-to-date" vc-dir-hide-up-to-date
		  :help "Hide up-to-date items from display"))
    ;; Movement.
    (define-key map [sepmv] '("--"))
    (define-key map [next-line]
      '(menu-item "Next Line" vc-dir-next-line
		  :help "Go to the next line" :keys "n"))
    (define-key map [previous-line]
      '(menu-item "Previous Line" vc-dir-previous-line
		  :help "Go to the previous line"))
    ;; Marking.
    (define-key map [sepmrk] '("--"))
    (define-key map [unmark-all]
      '(menu-item "Unmark All" vc-dir-unmark-all-files
		  :help "Unmark all files that are in the same state as the current file\
\nWith prefix argument unmark all files"))
    (define-key map [unmark-previous]
      '(menu-item "Unmark Previous " vc-dir-unmark-file-up
		  :help "Move to the previous line and unmark the file"))

    (define-key map [mark-unregistered]
      '(menu-item "Mark Unregistered" vc-dir-mark-unregistered-files
                  :help "Mark all files in the unregistered state"))
    (define-key map [mark-registered]
      '(menu-item "Mark Registered" vc-dir-mark-registered-files
                  :help "Mark all files in the state edited, added or removed"))
    (define-key map [mark-all]
      '(menu-item "Mark All" vc-dir-mark-all-files
		  :help "Mark all files that are in the same state as the current file\
\nWith prefix argument mark all files"))
    (define-key map [unmark]
      '(menu-item "Unmark" vc-dir-unmark
		  :help "Unmark the current file or all files in the region"))

    (define-key map [mark]
      '(menu-item "Mark" vc-dir-mark
		  :help "Mark the current file or all files in the region"))

    (define-key map [sepopn] '("--"))
    (define-key map [qr]
      '(menu-item "Query Replace in Files..." vc-dir-query-replace-regexp
		  :help "Replace a string in the marked files"))
    (define-key map [se]
      '(menu-item "Search Files..." vc-dir-search
		  :help "Search a regexp in the marked files"))
    (define-key map [ires]
      '(menu-item "Isearch Regexp Files..." vc-dir-isearch-regexp
		  :help "Incremental search a regexp in the marked files"))
    (define-key map [ise]
      '(menu-item "Isearch Files..." vc-dir-isearch
		  :help "Incremental search a string in the marked files"))
    (define-key map [display]
      '(menu-item "Display in Other Window" vc-dir-display-file
		  :help "Display the file on the current line, in another window"))
    (define-key map [open-other]
      '(menu-item "Open in Other Window" vc-dir-find-file-other-window
		  :help "Find the file on the current line, in another window"))
    (define-key map [open]
      '(menu-item "Open File" vc-dir-find-file
		  :help "Find the file on the current line"))
    (define-key map [delete]
      '(menu-item "Delete" vc-dir-clean-files
		  :help "Delete the unregistered marked files"))
    (define-key map [sepvcdet] '("--"))
    ;; FIXME: This needs a key binding.  And maybe a better name
    ;; ("Insert" like PCL-CVS uses does not sound that great either)...
    (define-key map [ins]
      '(menu-item "Show File" vc-dir-show-fileentry
		  :help "Show a file in the VC status listing even though it might be up to date"))
    (define-key map [annotate]
      '(menu-item "Annotate" vc-annotate
		  :help "Display the edit history of the current file using colors"))
    (define-key map [diff]
      '(menu-item "Compare with Base Version" vc-diff
		  :help "Compare file set with the base version"))
    (define-key map [logo]
      '(menu-item "Show Outgoing Log" vc-log-outgoing
		  :help "Show a log of changes that will be sent with a push operation"))
    (define-key map [logi]
      '(menu-item "Show Incoming Log" vc-log-incoming
		  :help "Show a log of changes that will be received with a pull operation"))
    (define-key map [log]
      '(menu-item "Show History" vc-print-log
		  :help "List the change log of the current file set in a window"))
    (define-key map [rlog]
      '(menu-item "Show Top of the Tree History " vc-print-root-log
		  :help "List the change log for the current tree in a window"))
    ;; VC commands.
    (define-key map [sepvccmd] '("--"))
    (define-key map [push]
      '(menu-item "Push Changes" vc-push
		  :enable (vc-find-backend-function vc-dir-backend 'push)
		  :help "Push the current branch's changes"))
    (define-key map [update]
      '(menu-item "Update to Latest Version" vc-pull
		  :help "Update the current fileset's files to their tip revisions"))
    (define-key map [revert]
      '(menu-item "Revert to Base Version" vc-revert
		  :help "Revert working copies of the selected fileset to their repository contents."))
    (define-key map [next-action]
      ;; FIXME: This really really really needs a better name!
      ;; And a key binding too.
      '(menu-item "Check In/Out" vc-next-action
		  :help "Do the next logical version control operation on the current fileset"))
    (define-key map [register]
      '(menu-item "Register" vc-register
		  :help "Register file set into the version control system"))
    (define-key map [ignore]
      '(menu-item "Ignore Current File" vc-dir-ignore
		  :help "Ignore the current file under current version control system"))
    map)
  "Menu for VC dir.")

;; VC backends can use this to add mode-specific menu items to
;; vc-dir-menu-map.
(defun vc-dir-menu-map-filter (orig-binding)
  (when (and (symbolp orig-binding) (fboundp orig-binding))
    (setq orig-binding (indirect-function orig-binding)))
  (let ((ext-binding
         (when (derived-mode-p 'vc-dir-mode)
	   (vc-call-backend vc-dir-backend 'extra-status-menu))))
    (if (null ext-binding)
	orig-binding
      (append orig-binding
	      '("----")
	      ext-binding))))

(defvar vc-dir-mode-map
  (let ((map (make-sparse-keymap)))
    ;; VC commands
    (define-key map "v" #'vc-next-action)   ;; C-x v v
    (define-key map "=" #'vc-diff)	   ;; C-x v =
    (define-key map "D" #'vc-root-diff)	   ;; C-x v D
    (define-key map "i" #'vc-register)	   ;; C-x v i
    (define-key map "+" #'vc-pull)	   ;; C-x v +
    ;; I'd prefer some kind of symmetry with vc-pull:
    (define-key map "P" #'vc-push)	   ;; C-x v P
    (define-key map "l" #'vc-print-log)	   ;; C-x v l
    (define-key map "L" #'vc-print-root-log) ;; C-x v L
    (define-key map "I" #'vc-log-incoming)   ;; C-x v I
    (define-key map "O" #'vc-log-outgoing)   ;; C-x v O
    ;; More confusing than helpful, probably
    ;;(define-key map "R" #'vc-revert) ;; u is taken by vc-dir-unmark.
    ;;(define-key map "A" #'vc-annotate) ;; g is taken by revert-buffer
    ;;                                     bound by `special-mode'.
    ;; Marking.
    (define-key map "m" #'vc-dir-mark)
    (define-key map "d" #'vc-dir-clean-files)
    (define-key map "M" #'vc-dir-mark-all-files)
    (define-key map "u" #'vc-dir-unmark)
    (define-key map "U" #'vc-dir-unmark-all-files)
    (define-key map "\C-?" #'vc-dir-unmark-file-up)
    (define-key map "\M-\C-?" #'vc-dir-unmark-all-files)
    ;; Movement.
    (define-key map "n" #'vc-dir-next-line)
    (define-key map " " #'vc-dir-next-line)
    (define-key map "\t" #'vc-dir-next-directory)
    (define-key map "p" #'vc-dir-previous-line)
    (define-key map [?\S-\ ] #'vc-dir-previous-line)
    (define-key map [backtab] #'vc-dir-previous-directory)
    ;;; Rebind paragraph-movement commands.
    (define-key map "\M-}" #'vc-dir-next-directory)
    (define-key map "\M-{" #'vc-dir-previous-directory)
    (define-key map [C-down] #'vc-dir-next-directory)
    (define-key map [C-up] #'vc-dir-previous-directory)
    ;; The remainder.
    (define-key map "f" #'vc-dir-find-file)
    (define-key map "e" #'vc-dir-find-file) ; dired-mode compatibility
    (define-key map "\C-m" #'vc-dir-find-file)
    (define-key map "o" #'vc-dir-find-file-other-window)
    (define-key map "\C-o" #'vc-dir-display-file)
    (define-key map "\C-c\C-c" #'vc-dir-kill-dir-status-process)
    (define-key map [down-mouse-3] #'vc-dir-menu)
    (define-key map [follow-link] 'mouse-face)
    (define-key map "x" #'vc-dir-hide-up-to-date)
    (define-key map [?\C-k] #'vc-dir-kill-line)
    (define-key map "S" #'vc-dir-search) ;; FIXME: Maybe use A like dired?
    (define-key map "Q" #'vc-dir-query-replace-regexp)
    (define-key map (kbd "M-s a C-s")   #'vc-dir-isearch)
    (define-key map (kbd "M-s a M-C-s") #'vc-dir-isearch-regexp)
    (define-key map "G" #'vc-dir-ignore)

    (let ((branch-map (make-sparse-keymap)))
      (define-key map "b" branch-map)
      (define-key branch-map "c" #'vc-create-branch)
      (define-key branch-map "l" #'vc-print-branch-log)
      (define-key branch-map "s" #'vc-switch-branch))

    (let ((regexp-map (make-sparse-keymap)))
      (define-key map "%" regexp-map)
      (define-key regexp-map "m" #'vc-dir-mark-by-regexp))

    (let ((mark-map (make-sparse-keymap)))
      (define-key map "*" mark-map)
      (define-key mark-map "%" #'vc-dir-mark-by-regexp)
      (define-key mark-map "r" #'vc-dir-mark-registered-files))

    ;; Hook up the menu.
    (define-key map [menu-bar vc-dir-mode]
      `(menu-item
	;; VC backends can use this to add mode-specific menu items to
	;; vc-dir-menu-map.
	"VC-Dir" ,vc-dir-menu-map :filter vc-dir-menu-map-filter))
    map)
  "Keymap for directory buffer.")

(when vc-use-incoming-outgoing-prefixes
  (keymap-set vc-dir-mode-map "I" vc-incoming-prefix-map)
  (keymap-set vc-dir-mode-map "O" vc-outgoing-prefix-map))

(defmacro vc-dir-at-event (event &rest body)
  "Evaluate BODY with point located at `event-start' of EVENT.
If BODY uses EVENT, it should be a variable,
 otherwise it will be evaluated twice."
  (let ((posn (make-symbol "vc-dir-at-event-posn")))
    `(save-excursion
       (unless (equal ,event '(tool-bar))
         (let ((,posn (event-start ,event)))
           (set-buffer (window-buffer (posn-window ,posn)))
           (goto-char (posn-point ,posn))))
       ,@body)))

(defun vc-dir-menu (e)
  "Popup the VC dir menu."
  (interactive "e")
  (vc-dir-at-event e (popup-menu vc-dir-menu-map e)))

(defvar vc-dir-tool-bar-map
  (let ((map (make-sparse-keymap)))
    (tool-bar-local-item-from-menu 'find-file "new" map nil
				   :label "New File" :vert-only t)
    (tool-bar-local-item-from-menu 'menu-find-file-existing "open" map nil
				   :label "Open" :vert-only t)
    (tool-bar-local-item-from-menu 'dired "diropen" map nil
				   :vert-only t)
    (tool-bar-local-item-from-menu 'quit-window "close" map vc-dir-mode-map
				   :vert-only t)
    (tool-bar-local-item-from-menu 'vc-next-action "saveas" map
				   vc-dir-mode-map :label "Commit")
    (tool-bar-local-item-from-menu 'vc-print-log "info"
    				   map vc-dir-mode-map
				   :label "Log")
    (define-key-after map [separator-1] menu-bar-separator)
    (tool-bar-local-item-from-menu 'vc-dir-kill-dir-status-process "cancel"
				   map vc-dir-mode-map
				   :label "Stop" :vert-only t)
    (tool-bar-local-item-from-menu 'revert-buffer "refresh"
				   map vc-dir-mode-map :vert-only t)
    (define-key-after map [separator-2] menu-bar-separator)
    (tool-bar-local-item-from-menu (lookup-key menu-bar-edit-menu [cut])
				   "cut" map nil :vert-only t)
    (tool-bar-local-item-from-menu (lookup-key menu-bar-edit-menu [copy])
				   "copy" map nil :vert-only t)
    (tool-bar-local-item-from-menu (lookup-key menu-bar-edit-menu [paste])
				   "paste" map nil :vert-only t)
    (define-key-after map [separator-3] menu-bar-separator)
    (tool-bar-local-item-from-menu 'isearch-forward
    				   "search" map nil
				   :label "Search" :vert-only t)
    map))

(defun vc-dir-node-directory (node)
  ;; Compute the directory for NODE.
  ;; If it's a directory node, get it from the node.
  (let ((data (ewoc-data node)))
    (or (vc-dir-fileinfo->directory data)
	;; Otherwise compute it from the file name.
	(file-name-directory
	 (directory-file-name
	  (expand-file-name
	   (vc-dir-fileinfo->name data)))))))

(defun vc-dir-update (entries buffer &optional noinsert)
  "Update BUFFER's VC-Dir ewoc from ENTRIES.
This has the effect of adding ENTRIES to the VC-Dir buffer BUFFER.
If optional argument NOINSERT is non-nil, update ewoc nodes, but don't
add elements of ENTRIES to the buffer that aren't already in the ewoc.
Also update some VC file properties from ENTRIES."
  (with-current-buffer buffer
    ;; Insert the entries sorted by name into the ewoc.
    ;; We assume the ewoc is sorted too, which should be the
    ;; case if we always add entries with vc-dir-update.
    (setq entries
          (let ((entry-dirs
                 (mapcar (lambda (entry)
                           (cons (file-name-directory
                                  (directory-file-name (expand-file-name (car entry))))
                                 entry))
                         entries)))
	  ;; Sort: first files and then subdirectories.
            (mapcar #'cdr
                    (sort entry-dirs
                          (lambda (pair1 pair2)
                            (let ((dir1 (car pair1))
                                  (dir2 (car pair2)))
                              (cond
                               ((string< dir1 dir2) t)
                               ((not (string= dir1 dir2)) nil)
                               ((string< (cadr pair1) (cadr pair2))))))))))
    ;; Insert directory entries in the right places.
    (let ((entry (car entries))
	  (node (ewoc-nth vc-ewoc 0))
	  (to-remove nil)
	  (dotname (file-relative-name default-directory)))
      ;; Insert . if it is not present.
      (unless node
	(ewoc-enter-last
	 vc-ewoc (vc-dir-create-fileinfo
		  dotname nil nil nil default-directory))
	(setq node (ewoc-nth vc-ewoc 0)))

      (while (and entry node)
	(let* ((entryfile (car entry))
	       (entrydir (file-name-directory (directory-file-name
					       (expand-file-name entryfile))))
	       (nodedir (vc-dir-node-directory node)))
	  (cond
	   ;; First try to find the directory.
	   ((string-lessp nodedir entrydir)
	    (setq node (ewoc-next vc-ewoc node)))
	   ((string-equal nodedir entrydir)
	    ;; Found the directory, find the place for the file name.
	    (let ((nodefile (vc-dir-fileinfo->name (ewoc-data node))))
	      (cond
	       ((string= nodefile dotname)
		(setq node (ewoc-next vc-ewoc node)))
	       ((string-lessp nodefile entryfile)
		(setq node (ewoc-next vc-ewoc node)))
	       ((string-equal nodefile entryfile)
		(if (nth 1 entry)
		    (progn
		      (setf (vc-dir-fileinfo->state (ewoc-data node)) (nth 1 entry))
		      (setf (vc-dir-fileinfo->extra (ewoc-data node)) (nth 2 entry))
		      (setf (vc-dir-fileinfo->needs-update (ewoc-data node)) nil)
		      (ewoc-invalidate vc-ewoc node))
		  ;; If the state is nil, the file does not exist
		  ;; anymore, so remember the entry so we can remove
		  ;; it after we are done inserting all ENTRIES.
		  (push node to-remove))
		(setq entries (cdr entries))
		(setq entry (car entries))
		(setq node (ewoc-next vc-ewoc node)))
	       (t
		(unless noinsert
		  (ewoc-enter-before vc-ewoc node
				     (apply #'vc-dir-create-fileinfo entry)))
		(setq entries (cdr entries))
		(setq entry (car entries))))))
	   (t
	    (unless noinsert
	      ;; We might need to insert a directory node if the
	      ;; previous node was in a different directory.
	      (let* ((rd (file-relative-name entrydir))
		     (prev-node (ewoc-prev vc-ewoc node))
		     (prev-dir (if prev-node
				   (vc-dir-node-directory prev-node))))
		(unless (string-equal entrydir prev-dir)
		  (ewoc-enter-before
		   vc-ewoc node (vc-dir-create-fileinfo rd nil nil nil entrydir))))
	      ;; Now insert the node itself.
	      (ewoc-enter-before vc-ewoc node
				 (apply #'vc-dir-create-fileinfo entry)))
	    (setq entries (cdr entries) entry (car entries))))))
      ;; We're past the last node, all remaining entries go to the end.
      (unless (or node noinsert)
	(let ((lastdir (vc-dir-node-directory (ewoc-nth vc-ewoc -1))))
	  (dolist (entry entries)
	    (let ((entrydir (file-name-directory
			     (directory-file-name (expand-file-name (car entry))))))
	      ;; Insert a directory node if needed.
	      (unless (string-equal lastdir entrydir)
		(setq lastdir entrydir)
		(let ((rd (file-relative-name entrydir)))
		  (ewoc-enter-last
		   vc-ewoc (vc-dir-create-fileinfo rd nil nil nil entrydir))))
	      ;; Now insert the node itself.
	      (ewoc-enter-last vc-ewoc
			       (apply #'vc-dir-create-fileinfo entry))))))
      (when to-remove
	(let ((inhibit-read-only t))
	  (apply #'ewoc-delete vc-ewoc (nreverse to-remove)))))
    ;; Update VC file properties.
    (pcase-dolist (`(,file ,state ,_extra) entries)
      (vc-file-setprop file 'vc-backend
                       (if (eq state 'unregistered) 'none vc-dir-backend)))))

(defun vc-dir-busy ()
  (and (buffer-live-p vc-dir-process-buffer)
       (get-buffer-process vc-dir-process-buffer)))

(defun vc-dir-kill-dir-status-process ()
  "Kill the temporary buffer and associated process."
  (interactive)
  (when (buffer-live-p vc-dir-process-buffer)
    (let ((proc (get-buffer-process vc-dir-process-buffer)))
      (when proc (delete-process proc))
      (setq vc-dir-process-buffer nil)
      (setq mode-line-process nil))))

(defun vc-dir-kill-query ()
  ;; Make sure that when the status buffer is killed the update
  ;; process running in background is also killed.
  (if (vc-dir-busy)
    (when (y-or-n-p "Status update process running, really kill status buffer? ")
      (vc-dir-kill-dir-status-process)
      t)
    t))

(defun vc-dir-next-line (arg)
  "Go to the next line.
With prefix argument ARG, move that many lines."
  (interactive "p")
  (with-no-warnings
    (ewoc-goto-next vc-ewoc arg)
    (vc-dir-move-to-goal-column)))

(defun vc-dir-previous-line (arg)
  "Go to the previous line.
With prefix argument ARG, move that many lines."
  (interactive "p")
  (ewoc-goto-prev vc-ewoc arg)
  (vc-dir-move-to-goal-column))

(defun vc-dir-next-directory ()
  "Go to the next directory."
  (interactive)
  (let ((orig (point)))
    (if
	(catch 'foundit
	  (while t
	    (let* ((next (ewoc-next vc-ewoc (ewoc-locate vc-ewoc))))
	      (cond ((not next)
		     (throw 'foundit t))
		    (t
		     (progn
		       (ewoc-goto-node vc-ewoc next)
		       (vc-dir-move-to-goal-column)
		       (if (vc-dir-fileinfo->directory (ewoc-data next))
			   (throw 'foundit nil))))))))
	(goto-char orig))))

(defun vc-dir-previous-directory ()
  "Go to the previous directory."
  (interactive)
  (let ((orig (point)))
    (if
	(catch 'foundit
	  (while t
	    (let* ((prev (ewoc-prev vc-ewoc (ewoc-locate vc-ewoc))))
	      (cond ((not prev)
		     (throw 'foundit t))
		    (t
		     (progn
		       (ewoc-goto-node vc-ewoc prev)
		       (vc-dir-move-to-goal-column)
		       (if (vc-dir-fileinfo->directory (ewoc-data prev))
			   (throw 'foundit nil))))))))
	(goto-char orig))))

(defun vc-dir-mark-unmark (mark-unmark-function)
  (if (use-region-p)
      (let ((processed-line nil)
	    (lastl (line-number-at-pos (region-end))))
	(save-excursion
	  (goto-char (region-beginning))
	  (while (and (<= (line-number-at-pos) lastl)
                      ;; We make sure to not get stuck processing the
                      ;; same line in an infinite loop.
		      (not (eq processed-line (line-number-at-pos))))
	    (setq processed-line (line-number-at-pos))
	    (condition-case nil
		(funcall mark-unmark-function)
	      ;; `vc-dir-mark-file' signals an error if we try marking
	      ;; a directory containing marked files in its tree, or a
	      ;; file in a marked directory tree.  Just continue.
	      (error (vc-dir-next-line 1))))))
    (funcall mark-unmark-function)))

(defun vc-dir--parent (arg &optional if-marked)
  "Return the parent node of ARG.
If IF-MARKED, return the nearest marked parent."
  (let* ((argdir (vc-dir-node-directory arg))
	 ;; (arglen (length argdir))
	 (crt arg)
	 (found nil))
    ;; Go through the predecessors, checking if any directory that is
    ;; a parent is marked.
    (while (and (null found)
		(setq crt (ewoc-prev vc-ewoc crt)))
      (let ((data (ewoc-data crt))
	    (dir (vc-dir-node-directory crt)))
	(and (vc-dir-fileinfo->directory data)
	     (string-prefix-p dir argdir)
	     (or (not if-marked) (vc-dir-fileinfo->marked data))
	     (setq found crt))))
    found))

(defun vc-dir--children (arg &optional only-marked)
  "Return a list of children of ARG.  If ONLY-MARKED, only those marked."
  (let* ((argdir-re (concat "\\`"
                            (regexp-quote (vc-dir-node-directory arg))))
	 (is-child t)
	 (crt arg)
	 (found nil))
    (while (and is-child
		(setq crt (ewoc-next vc-ewoc crt)))
      (if (string-match argdir-re (vc-dir-node-directory crt))
	  (when (or (not only-marked)
                    (vc-dir-fileinfo->marked (ewoc-data crt)))
	    (push crt found))
	;; We are done, we got to an entry that is not a child of `arg'.
	(setq is-child nil)))
    found))

(defun vc-dir-mark-file (&optional arg)
  ;; Mark ARG or the current file and move to the next line.
  (let* ((crt (or arg (ewoc-locate vc-ewoc)))
         (file (ewoc-data crt))
         (to-inval (list crt)))
    ;; We do not allow a state in which a directory is marked and also
    ;; some of its files are marked.  If the user's intent is clear,
    ;; adjust things for them so that they can proceed.
    (if-let* (((vc-dir-fileinfo->directory file))
              (children (vc-dir--children crt t)))
        ;; The user wants to mark a directory where some of its children
        ;; are already marked.  The user's intent is quite clear, so
        ;; unconditionally unmark the children.
        (dolist (child children)
          (setf (vc-dir-fileinfo->marked (ewoc-data child)) nil)
          (push child to-inval))
      (when-let* ((parent (vc-dir--parent crt t))
                  (name (vc-dir-fileinfo->name (ewoc-data parent))))
        ;; The user seems to want to mark an entry whose directory is
        ;; already marked.  As the file is already implicitly marked for
        ;; most VCS, they may not really intend this.
        (when (or (not vc-dir-allow-mass-mark-changes)
                  (and (eq vc-dir-allow-mass-mark-changes 'ask)
                       (not (yes-or-no-p
                             (format "`%s' is already marked; unmark it?"
                                     name)))))
          (error "`%s' is already marked" name))
        (setf (vc-dir-fileinfo->marked (ewoc-data parent)) nil)
        (push parent to-inval)))
    (setf (vc-dir-fileinfo->marked file) t)
    (apply #'ewoc-invalidate vc-ewoc to-inval)
    (unless (or arg (mouse-event-p last-command-event))
      (vc-dir-next-line 1))))

(defun vc-dir-mark ()
  "Mark the current file or all files in the region.
If the region is active, mark all the files in the region.
Otherwise mark the file on the current line and move to the next
line."
  (interactive)
  (vc-dir-mark-unmark 'vc-dir-mark-file))

(defun vc-dir-mark-all-files (arg)
  "Mark all files with the same state as the current one.
With prefix argument ARG, mark all files (not directories).
If the current entry is a directory, mark all child files.

The commands operate on files that are on the same state.
This command is intended to make it easy to select all files that
share the same state."
  (interactive "P")
  (if arg
      ;; Mark all files.
      (progn
	;; First check that no directory is marked, we can't mark
	;; files in that case.
	(ewoc-map
	 (lambda (filearg)
	   (when (and (vc-dir-fileinfo->directory filearg)
		      (vc-dir-fileinfo->marked filearg))
	     (error "Cannot mark all files, directory `%s' marked"
		    (vc-dir-fileinfo->name filearg))))
	 vc-ewoc)
	(ewoc-map
	 (lambda (filearg)
	   (unless (or (vc-dir-fileinfo->directory filearg)
                       (vc-dir-fileinfo->marked filearg))
	     (setf (vc-dir-fileinfo->marked filearg) t)
	     t))
	 vc-ewoc))
    (let* ((crt  (ewoc-locate vc-ewoc))
	   (data (ewoc-data crt)))
      (if (vc-dir-fileinfo->directory data)
	  ;; It's a directory, mark child files.
	  (let (crt-data)
	    (while (and (setq crt (ewoc-next vc-ewoc crt))
			(setq crt-data (ewoc-data crt))
			(not (vc-dir-fileinfo->directory crt-data)))
	      (setf (vc-dir-fileinfo->marked crt-data) t)
	      (ewoc-invalidate vc-ewoc crt)))
	;; It's a file
	(let ((state (vc-dir-fileinfo->state data)))
	  (setq crt (ewoc-nth vc-ewoc 0))
	  (while crt
	    (let ((crt-data (ewoc-data crt)))
	      (when (and (not (vc-dir-fileinfo->marked crt-data))
			 (eq (vc-dir-fileinfo->state crt-data) state)
			 (not (vc-dir-fileinfo->directory crt-data)))
		(vc-dir-mark-file crt)))
	    (setq crt (ewoc-next vc-ewoc crt))))))))

(defun vc-dir-mark-by-regexp (regexp &optional unmark)
  "Mark all files that match REGEXP.
If UNMARK (interactively, the prefix), unmark instead."
  (interactive "sMark files matching: \nP")
  (ewoc-map
   (lambda (filearg)
     (when (and (not (vc-dir-fileinfo->directory filearg))
                (eq (not unmark)
                    (not (vc-dir-fileinfo->marked filearg)))
                ;; We don't want to match on the part of the file
                ;; that's above the current directory.
                (string-match-p regexp (file-relative-name
                                        (vc-dir-fileinfo->name filearg))))
       (setf (vc-dir-fileinfo->marked filearg) (not unmark))
       t))
   vc-ewoc))

(defun vc-dir-mark-files (mark-files)
  "Mark files specified by file names in the argument MARK-FILES.
MARK-FILES should be a list of absolute filenames.
Directories must have trailing slashes."
  ;; Filter out subitems that would be implicitly marked.
  (setq mark-files (sort mark-files))
  (let ((next mark-files))
    (while next
      (when (string-suffix-p "/" (car next))
        (while (string-prefix-p (car next) (cadr next))
          (rplacd next (cddr next))))
      (setq next (cdr next))))

  (ewoc-map
   (lambda (filearg)
     (when (member (expand-file-name (vc-dir-fileinfo->name filearg))
                   mark-files)
       (setf (vc-dir-fileinfo->marked filearg) t)
       t))
   vc-ewoc))

(defun vc-dir-mark-state-files (states)
  "Mark files that are in the state specified by the list in STATES."
  (setq states (ensure-list states))
  (ewoc-map
   (lambda (filearg)
     (when (memq (vc-dir-fileinfo->state filearg) states)
       (setf (vc-dir-fileinfo->marked filearg) t)
       t))
   vc-ewoc))

(defun vc-dir-mark-registered-files ()
  "Mark files that are in one of registered states: edited, added or removed."
  (interactive)
  (vc-dir-mark-state-files '(edited added removed)))

(defun vc-dir-mark-unregistered-files ()
  "Mark files that are in unregistered state."
  (interactive)
  (vc-dir-mark-state-files 'unregistered))

(defun vc-dir-unmark-file ()
  ;; Unmark the current file and move to the next line.
  (let* ((crt (ewoc-locate vc-ewoc))
         (file (ewoc-data crt))
         to-inval)
    (if (vc-dir-fileinfo->marked file)
        (progn (setf (vc-dir-fileinfo->marked file) nil)
               (push crt to-inval))
      ;; The current item is not explicitly marked, but its containing
      ;; directory is marked.  So this item is implicitly marked, for
      ;; most VCS.  Offer to change that.
      (if-let* ((parent (vc-dir--parent crt t))
                (all-children (vc-dir--children parent)))
          (when (and vc-dir-allow-mass-mark-changes
                     (or (not (eq vc-dir-allow-mass-mark-changes 'ask))
                         (yes-or-no-p
                          (format "\
Replace mark on `%s' with marks on all subitems but this one?"
                                  (vc-dir-fileinfo->name file)))))
            (let ((subtree (if (vc-dir-fileinfo->directory file)
                               (cons crt (vc-dir--children crt))
                             (list crt (vc-dir--parent crt)))))
              (setf (vc-dir-fileinfo->marked (ewoc-data parent)) nil)
              (push parent to-inval)
              (dolist (child all-children)
                (setf (vc-dir-fileinfo->marked (ewoc-data child))
                      (not (memq child subtree)))
                (push child to-inval))))
        ;; The current item is a directory that's not marked, implicitly
        ;; or explicitly, but it has marked items below it.
        ;; Offer to unmark those.
        (when-let*
            (((vc-dir-fileinfo->directory file))
             (children (vc-dir--children crt t))
             ((and vc-dir-allow-mass-mark-changes
                   (or (not (eq vc-dir-allow-mass-mark-changes 'ask))
                       (yes-or-no-p
                        (format "Unmark all items within `%s'?"
                                (vc-dir-fileinfo->name file)))))))
          (dolist (child children)
            (setf (vc-dir-fileinfo->marked (ewoc-data child)) nil)
            (push child to-inval)))))
    (when to-inval
      (apply #'ewoc-invalidate vc-ewoc to-inval))
    (unless (mouse-event-p last-command-event)
      (vc-dir-next-line 1))))

(defun vc-dir-unmark ()
  "Unmark the current file or all files in the region.
If the region is active, unmark all the files in the region.
Otherwise unmark the file on the current line and move to the next
line."
  (interactive)
  (vc-dir-mark-unmark 'vc-dir-unmark-file))

(defun vc-dir-unmark-file-up ()
  "Move to the previous line and unmark the file."
  (interactive)
  ;; If we're on the first line, we won't move up, but we will still
  ;; remove the mark.  This seems a bit odd but it is what buffer-menu
  ;; does.
  (let* ((prev (ewoc-goto-prev vc-ewoc 1))
	 (file (ewoc-data prev)))
    (setf (vc-dir-fileinfo->marked file) nil)
    (ewoc-invalidate vc-ewoc prev)
    (vc-dir-move-to-goal-column)))

(defun vc-dir-unmark-all-files (arg)
  "Unmark all files with the same state as the current one.
With prefix argument ARG, unmark all files.
If the current entry is a directory, unmark all the child files.

The commands operate on files that are on the same state.
This command is intended to make it easy to deselect all files
that share the same state."
  (interactive "P")
  (if arg
      (ewoc-map
       (lambda (filearg)
	 (when (vc-dir-fileinfo->marked filearg)
	   (setf (vc-dir-fileinfo->marked filearg) nil)
	   t))
       vc-ewoc)
    (let* ((crt (ewoc-locate vc-ewoc))
	   (data (ewoc-data crt)))
      (if (vc-dir-fileinfo->directory data)
	  ;; It's a directory, unmark child files.
	  (while (setq crt (ewoc-next vc-ewoc crt))
	    (let ((crt-data (ewoc-data crt)))
	      (unless (vc-dir-fileinfo->directory crt-data)
		(setf (vc-dir-fileinfo->marked crt-data) nil)
		(ewoc-invalidate vc-ewoc crt))))
	;; It's a file
	(let ((crt-state (vc-dir-fileinfo->state (ewoc-data crt))))
	  (ewoc-map
	   (lambda (filearg)
	     (when (and (vc-dir-fileinfo->marked filearg)
			(eq (vc-dir-fileinfo->state filearg) crt-state))
	       (setf (vc-dir-fileinfo->marked filearg) nil)
	       t))
	   vc-ewoc))))))

(defun vc-dir-toggle-mark-file ()
  (let* ((crt (ewoc-locate vc-ewoc))
         (file (ewoc-data crt)))
    (if (vc-dir-fileinfo->marked file)
	(vc-dir-unmark-file)
      (vc-dir-mark-file))))

(defun vc-dir-toggle-mark (e)
  (interactive "e")
  (vc-dir-at-event e (vc-dir-mark-unmark 'vc-dir-toggle-mark-file)))

(defun vc-dir-clean-files ()
  "Delete the marked files, or the current file if no marks.
The files will not be marked as deleted in the version control
system; see `vc-dir-delete-file'."
  (interactive)
  (let* ((files (or (vc-dir-marked-files)
                    (list (vc-dir-current-file))))
         (tracked
          (seq-filter (lambda (file)
                        (not (eq (vc-call-backend vc-dir-backend 'state file)
                                 'unregistered)))
                      files)))
    (when tracked
      (user-error (ngettext "Trying to clean tracked file: %s"
                            "Trying to clean tracked files: %s"
                            (length tracked))
                  (mapconcat #'file-name-nondirectory tracked ", ")))
    (map-y-or-n-p "Delete %s? " #'delete-file files)
    (revert-buffer)))

(defun vc-dir-delete-file ()
  "Delete the marked files, or the current file if no marks.
The files will also be marked as deleted in the version control
system."
  (interactive)
  (mapc #'vc-delete-file (or (vc-dir-marked-files)
                            (list (vc-dir-current-file)))))

(defun vc-dir-find-file ()
  "Find the file on the current line."
  (interactive)
  (find-file (vc-dir-current-file)))

(defun vc-dir-find-file-other-window (&optional event)
  "Find the file on the current line, in another window."
  (interactive (list last-nonmenu-event))
  (if event (posn-set-point (event-end event)))
  (find-file-other-window (vc-dir-current-file)))

(defun vc-dir-display-file (&optional event)
  "Display the file on the current line, in another window."
  (interactive (list last-nonmenu-event))
  (if event (posn-set-point (event-end event)))
  (display-buffer (find-file-noselect (vc-dir-current-file))
		  t))

(defun vc-dir-view-file ()
  "Examine a file on the current line in view mode."
  (interactive)
  (view-file (vc-dir-current-file)))

(defun vc-dir-isearch ()
  "Search for a string through all marked buffers using Isearch."
  (interactive)
  (multi-isearch-files
   (mapcar #'car (vc-dir-marked-only-files-and-states))))

(defun vc-dir-isearch-regexp ()
  "Search for a regexp through all marked buffers using Isearch."
  (interactive)
  (multi-isearch-files-regexp
   (mapcar #'car (vc-dir-marked-only-files-and-states))))

(defun vc-dir-search (regexp)
  "Search through all marked files for a match for REGEXP.
For marked directories, use the files displayed from those directories.
Stops when a match is found.
To continue searching for next match, use command \\[fileloop-continue]."
  (interactive "sSearch marked files (regexp): ")
  (tags-search regexp
               (mapcar #'car (vc-dir-marked-only-files-and-states))))

(defun vc-dir-query-replace-regexp (from to &optional delimited)
  "Do `query-replace-regexp' of FROM with TO, on all marked files.
If a directory is marked, then use the files displayed for that directory.
Third arg DELIMITED (prefix arg) means replace only word-delimited matches.

As each match is found, the user must type a character saying
what to do with it.  Type SPC or `y' to replace the match,
DEL or `n' to skip and go to the next match.  For more directions,
type \\[help-command] at that time.

If you exit (\\[keyboard-quit], RET or q), you can resume the query replace
with the command \\[fileloop-continue]."
  ;; FIXME: this is almost a copy of `dired-do-query-replace-regexp'.  This
  ;; should probably be made generic and used in both places instead of
  ;; duplicating it here.
  (interactive
   (let ((common
	  (query-replace-read-args
	   "Query replace regexp in marked files" t t)))
     (list (nth 0 common) (nth 1 common) (nth 2 common))))
  (dolist (file (mapcar #'car (vc-dir-marked-only-files-and-states)))
    (let ((buffer (get-file-buffer file)))
      (if (and buffer (with-current-buffer buffer
			buffer-read-only))
	  (error "File `%s' is visited read-only" file))))
  (fileloop-initialize-replace
   from to (mapcar #'car (vc-dir-marked-only-files-and-states))
   (if (equal from (downcase from)) nil 'default)
   delimited)
  (fileloop-continue))

(defun vc-dir-ignore (&optional arg)
  "Ignore the current file.
If a prefix argument is given, ignore all marked files."
  (interactive "P")
  (if arg
      (ewoc-map
       (lambda (filearg)
	 (when (vc-dir-fileinfo->marked filearg)
	   (vc-ignore (vc-dir-fileinfo->name filearg))
	   t))
       vc-ewoc)
    (let ((rel-dir (vc--ignore-base-dir)))
      (vc-ignore
       (file-relative-name (vc-dir-current-file) rel-dir)
       rel-dir))))

(defun vc-dir-current-file ()
  (let ((node (ewoc-locate vc-ewoc)))
    (unless node
      (error "No file available"))
    (expand-file-name (vc-dir-fileinfo->name (ewoc-data node)))))

(defun vc-dir-marked-files ()
  "Return the list of marked files."
  (mapcar
   (lambda (elem) (expand-file-name (vc-dir-fileinfo->name elem)))
   (ewoc-collect vc-ewoc 'vc-dir-fileinfo->marked)))

(defun vc-dir-marked-only-files-and-states ()
  "Return the list of conses (FILE . STATE) for the marked files.
For marked directories return the corresponding conses for the
child files."
  (let ((crt (ewoc-nth vc-ewoc 0))
	result)
    (while crt
      (let ((crt-data (ewoc-data crt)))
	(if (vc-dir-fileinfo->marked crt-data)
	    ;; FIXME: use vc-dir-child-files-and-states here instead of duplicating it.
	    (if (vc-dir-fileinfo->directory crt-data)
		(let* ((dir (vc-dir-fileinfo->directory crt-data))
		       ;; (dirlen (length dir))
		       data)
		  (while
		      (and (setq crt (ewoc-next vc-ewoc crt))
			   (string-prefix-p dir
                                               (progn
                                                 (setq data (ewoc-data crt))
                                                 (vc-dir-node-directory crt))))
		    (unless (vc-dir-fileinfo->directory data)
		      (push
		       (cons (expand-file-name (vc-dir-fileinfo->name data))
			     (vc-dir-fileinfo->state data))
		       result))))
	      (push (cons (expand-file-name (vc-dir-fileinfo->name crt-data))
			  (vc-dir-fileinfo->state crt-data))
		    result)
	      (setq crt (ewoc-next vc-ewoc crt)))
	  (setq crt (ewoc-next vc-ewoc crt)))))
    (nreverse result)))

(defun vc-dir-child-files-and-states ()
  "Return the state of one or more files for the current entry.
If the entry is a directory, return the list of states of its child
files, where each file is described by a cons of the form (FILE . STATE).
If the entry is a file, return a single cons cell (FILE . STATE) for
that file."
  (let* ((crt (ewoc-locate vc-ewoc))
	 (crt-data (ewoc-data crt))
         result)
    (if (vc-dir-fileinfo->directory crt-data)
	(let* ((dir (vc-dir-fileinfo->directory crt-data))
	       ;; (dirlen (length dir))
	       data)
	  (while
	      (and (setq crt (ewoc-next vc-ewoc crt))
                   (string-prefix-p dir (progn
                                             (setq data (ewoc-data crt))
                                             (vc-dir-node-directory crt))))
	    (unless (vc-dir-fileinfo->directory data)
	      (push
	       (cons (expand-file-name (vc-dir-fileinfo->name data))
		     (vc-dir-fileinfo->state data))
	       result))))
      (push
       (cons (expand-file-name (vc-dir-fileinfo->name crt-data))
	     (vc-dir-fileinfo->state crt-data)) result))
    (nreverse result)))

(defun vc-dir-recompute-file-state (fname def-dir)
  (let* ((file-short (file-relative-name fname def-dir))
	 (_remove-me-when-CVS-works
	  (when (eq vc-dir-backend 'CVS)
	    ;; FIXME: Warning: UGLY HACK.  The CVS backend caches the state
	    ;; info, this forces the backend to update it.
	    (vc-call-backend vc-dir-backend 'registered fname)))
	 (state (vc-call-backend vc-dir-backend 'state fname))
	 (extra (vc-call-backend vc-dir-backend
				 'status-fileinfo-extra fname)))
    (list file-short state extra)))

(defun vc-dir-find-child-files (dirname)
  ;; Give a DIRNAME string return the list of all child files shown in
  ;; the current *vc-dir* buffer.
  (let ((crt (ewoc-nth vc-ewoc 0))
	children)
    ;; Find DIR
    (while (and crt (not (string-prefix-p
			  dirname (vc-dir-node-directory crt))))
      (setq crt (ewoc-next vc-ewoc crt)))
    (while (and crt (string-prefix-p
		     dirname
                     (vc-dir-node-directory crt)))
      (let ((data (ewoc-data crt)))
	(unless (vc-dir-fileinfo->directory data)
	  (push (expand-file-name (vc-dir-fileinfo->name data)) children)))
      (setq crt (ewoc-next vc-ewoc crt)))
    children))

(defun vc-dir-resync-directory-files (dirname)
  ;; Update the entries for all the child files of DIRNAME shown in
  ;; the current *vc-dir* buffer.
  (let ((files (vc-dir-find-child-files dirname))
	(ddir default-directory)
	fileentries)
    (when files
      (dolist (crt files)
	(push (vc-dir-recompute-file-state crt ddir)
	      fileentries))
      (vc-dir-update fileentries (current-buffer)))))

(defun vc-dir-resynch-file (&optional fname)
  "Update the entries for FNAME in any directory buffers that list it."
  (let ((file (expand-file-name (or fname buffer-file-name)))
        (drop '()))
    (save-current-buffer
      ;; look for a vc-dir buffer that might show this file.
      (dolist (status-buf vc-dir-buffers)
        (if (not (buffer-live-p status-buf))
            (push status-buf drop)
          (set-buffer status-buf)
          (if (not (derived-mode-p 'vc-dir-mode))
              (push status-buf drop)
            (let ((ddir default-directory))
              (when (string-prefix-p ddir file)
                (if (file-directory-p file)
		    (progn
		      (vc-dir-resync-directory-files file)
		      (ewoc-set-hf vc-ewoc
				   (vc-dir-headers vc-dir-backend default-directory) ""))
                  (let* ((complete-state (vc-dir-recompute-file-state file ddir))
			 (state (cadr complete-state)))
                    (vc-dir-update
                     (list complete-state)
                     status-buf (or (not state)
				    (eq state 'up-to-date)))))))))))
    ;; Remove out-of-date entries from vc-dir-buffers.
    (dolist (b drop) (setq vc-dir-buffers (delq b vc-dir-buffers)))))

(defvar use-vc-backend)  ;; dynamically bound

(define-derived-mode vc-dir-mode special-mode "VC dir"
  "Major mode for VC directory buffers.
Marking/Unmarking key bindings and actions: \\<vc-dir-mode-map>
\\[vc-dir-mark] - mark a file/directory
  - if the region is active, mark all the files in region.
    Restrictions: - a file cannot be marked if any parent directory is marked
                  - a directory cannot be marked if any child file or
                    directory is marked
\\[vc-dir-unmark] - unmark a file/directory
  - if the region is active, unmark all the files in region.
\\[vc-dir-mark-all-files] - if the cursor is on a file: mark all the files with the same state as
      the current file
  - if the cursor is on a directory: mark all child files
  - with a prefix argument: mark all files
\\[vc-dir-unmark-all-files] - if the cursor is on a file: unmark all the files with the same state
      as the current file
  - if the cursor is on a directory: unmark all child files
  - with a prefix argument: unmark all files

VC commands
VC commands in the \\[vc-prefix-map] prefix can be used.
VC commands act on the marked entries.  If nothing is marked, VC
commands act on the current entry.

Search & Replace
\\[vc-dir-search] - searches the marked files
\\[vc-dir-query-replace-regexp] - does a query replace on the marked files
\\[vc-dir-isearch] - does an isearch on the marked files
\\[vc-dir-isearch-regexp] - does a regexp isearch on the marked files
If nothing is marked, these commands act on the current entry.
When a directory is current or marked, the Search & Replace
commands act on the child files of that directory that are displayed in
the *vc-dir* buffer.

\\{vc-dir-mode-map}"
  (setq-local vc-dir-backend use-vc-backend)
  (setq-local desktop-save-buffer 'vc-dir-desktop-buffer-misc-data)
  (setq-local bookmark-make-record-function #'vc-dir-bookmark-make-record)
  (setq buffer-read-only t)
  (when (boundp 'tool-bar-map)
    (setq-local tool-bar-map vc-dir-tool-bar-map))
  (let ((buffer-read-only nil))
    (erase-buffer)
    (setq-local vc-dir-process-buffer nil)
    (setq-local vc-ewoc (ewoc-create #'vc-dir-printer))
    (setq-local revert-buffer-function 'vc-dir-revert-buffer-function)
    (setq list-buffers-directory (expand-file-name "*vc-dir*" default-directory))
    (add-to-list 'vc-dir-buffers (current-buffer))
    ;; Make sure that if the directory buffer is killed, the update
    ;; process running in the background is also killed.
    (add-hook 'kill-buffer-query-functions #'vc-dir-kill-query nil t)
    (hack-dir-local-variables-non-file-buffer)
    (vc-dir-refresh)))

(defun vc-dir-headers (backend dir)
  "Display the headers in the *VC dir* buffer.
It calls the `dir-extra-headers' backend method to display backend
specific headers."
  (concat
   ;; First layout the common headers.
   (propertize "VC backend : " 'face 'vc-dir-header)
   (propertize (format "%s\n" backend) 'face 'vc-dir-header-value)
   (propertize "Working dir: " 'face 'vc-dir-header)
   (propertize (format "%s\n" (abbreviate-file-name dir))
               'face 'vc-dir-header-value)
   ;; Then the backend specific ones.
   (vc-call-backend backend 'dir-extra-headers dir)
   "\n"))

(defun vc-dir-refresh-files (files)
  "Refresh some FILES in the *VC-dir* buffer."
  (let ((def-dir default-directory)
	(backend vc-dir-backend))
    (vc-set-mode-line-busy-indicator)
    ;; Call the `dir-status-files' backend function.
    ;; `dir-status-files' is supposed to be asynchronous.
    ;; It should compute the results, and then call the function
    ;; passed as an argument in order to update the vc-dir buffer
    ;; with the results.
    (unless (buffer-live-p vc-dir-process-buffer)
      (setq vc-dir-process-buffer
            (generate-new-buffer (format " *VC-%s* tmp status" backend))))
    (let ((buffer (current-buffer)))
      (with-current-buffer vc-dir-process-buffer
        (setq default-directory def-dir)
        (erase-buffer)
        (vc-call-backend
         backend 'dir-status-files def-dir files
         (lambda (entries &optional more-to-come)
           ;; ENTRIES is a list of (FILE VC_STATE EXTRA) items.
           ;; If MORE-TO-COME is true, then more updates will come from
           ;; the asynchronous process.
           (with-current-buffer buffer
             (vc-dir-update entries buffer)
             (unless more-to-come
               (setq mode-line-process nil)
               ;; Remove the ones that haven't been updated at all.
               ;; Those not-updated are those whose state is nil because the
               ;; file/dir doesn't exist and isn't versioned.
               (ewoc-filter vc-ewoc
                            (lambda (info)
			      ;; The state for directory entries might
			      ;; have been changed to 'up-to-date,
			      ;; reset it, otherwise it will be removed when doing 'x'
			      ;; next time.
			      ;; FIXME: There should be a more elegant way to do this.
			      (when (and (vc-dir-fileinfo->directory info)
					 (eq (vc-dir-fileinfo->state info)
					     'up-to-date))
				(setf (vc-dir-fileinfo->state info) nil))

                              (not (vc-dir-fileinfo->needs-update info))))))))))))

(defun vc-dir-revert-buffer-function (&optional _ignore-auto _noconfirm)
  (vc-dir-refresh)
  (when vc-dir-hide-up-to-date-on-revert
    (vc-dir-hide-state)))

(defun vc-dir-refresh ()
  "Refresh the contents of the *VC-dir* buffer.
Throw an error if another update process is in progress."
  (interactive)
  (if (vc-dir-busy)
      (error "Another update process is in progress, cannot run two at a time")
    (let ((def-dir default-directory)
	  (backend vc-dir-backend))
      (when vc-dir-save-some-buffers-on-revert
        (vc-buffer-sync-fileset `(,vc-dir-backend (,def-dir)) t))
      (vc-set-mode-line-busy-indicator)
      ;; Call the `dir-status' backend function.
      ;; `dir-status' is supposed to be asynchronous.
      ;; It should compute the results, and then call the function
      ;; passed as an argument in order to update the vc-dir buffer
      ;; with the results.

      ;; Create a buffer that can be used by `dir-status' and call
      ;; `dir-status' with this buffer as the current buffer.  Use
      ;; `vc-dir-process-buffer' to remember this buffer, so that
      ;; it can be used later to kill the update process in case it
      ;; takes too long.
      (unless (buffer-live-p vc-dir-process-buffer)
        (setq vc-dir-process-buffer
              (generate-new-buffer (format " *VC-%s* tmp status" backend))))
      ;; set the needs-update flag on all non-directory entries
      (ewoc-map (lambda (info)
		  (unless (vc-dir-fileinfo->directory info)
		    (setf (vc-dir-fileinfo->needs-update info) t) nil))
                vc-ewoc)
      ;; Bzr has serious locking problems, so setup the headers first (this is
      ;; synchronous) rather than doing it while dir-status is running.
      (ewoc-set-hf vc-ewoc (vc-dir-headers backend def-dir) "")
      (let ((buffer (current-buffer)))
        (with-current-buffer vc-dir-process-buffer
          (setq default-directory def-dir)
          (erase-buffer)
          (vc-call-backend
           backend 'dir-status-files def-dir nil
           (lambda (entries &optional more-to-come)
             ;; ENTRIES is a list of (FILE VC_STATE EXTRA) items.
             ;; If MORE-TO-COME is true, then more updates will come from
             ;; the asynchronous process.
             (with-current-buffer buffer
               (vc-dir-update entries buffer)
               (unless more-to-come
                 (let ((remaining
                        (ewoc-collect
                         vc-ewoc 'vc-dir-fileinfo->needs-update)))
                   (if remaining
                       (vc-dir-refresh-files
                        (mapcar #'vc-dir-fileinfo->name remaining))
                     (setq mode-line-process nil)
                     (run-hooks 'vc-dir-refresh-hook))))))))))))

(defun vc-dir-show-fileentry (file)
  "Insert an entry for a specific file into the current *VC-dir* listing.
This is typically used if the file is up-to-date (or has been added
outside of VC) and one wants to do some operation on it."
  (interactive "fShow file: ")
  (vc-dir-update (list (list (file-relative-name file) (vc-state file))) (current-buffer)))

(defun vc-dir-hide-state (&optional state)
  "Hide items that are in STATE from display.
See `vc-state' for valid values of STATE.

If STATE is nil, hide both `up-to-date' and `ignored' items.

Interactively, if `current-prefix-arg' is non-nil, set STATE to
state of item at point, if any."
  (interactive (list
		(and current-prefix-arg
		     ;; Command is prefixed.  Infer STATE from point.
		     (let ((node (ewoc-locate vc-ewoc)))
		       (and node (vc-dir-fileinfo->state (ewoc-data node)))))))
  (if state
      (message "Hiding items in state \"%s\"" state)
    (message "Hiding up-to-date and ignored items"))
  (let ((crt (ewoc-nth vc-ewoc -1))
	(first (ewoc-nth vc-ewoc 0)))
    ;; Go over from the last item to the first and remove the
    ;; up-to-date files and directories with no child files.
    (while (not (eq crt first))
      (let* ((data (ewoc-data crt))
	     (dir (vc-dir-fileinfo->directory data))
	     (next (ewoc-next vc-ewoc crt))
	     (prev (ewoc-prev vc-ewoc crt))
	     ;; ewoc-delete does not work without this...
	     (inhibit-read-only t))
	(when (or
	       ;; Remove directories with no child files.
	       (and dir
		    (or
		     ;; Nothing follows this directory.
		     (not next)
		     ;; Next item is a directory.
		     (vc-dir-fileinfo->directory (ewoc-data next))))
	       ;; Remove files in specified STATE.  STATE can be a
	       ;; symbol, a user-name, or nil.
               (if state
                   (equal (vc-dir-fileinfo->state data) state)
                 (memq (vc-dir-fileinfo->state data) '(up-to-date ignored))))
	  (ewoc-delete vc-ewoc crt))
	(setq crt prev)))))

(defalias 'vc-dir-hide-up-to-date #'vc-dir-hide-state)

(defun vc-dir-kill-line ()
  "Remove the current line from display."
  (interactive)
  (let ((crt (ewoc-locate vc-ewoc))
        (inhibit-read-only t))
    (ewoc-delete vc-ewoc crt)))

(defun vc-dir-printer (fileentry)
  (vc-call-backend vc-dir-backend 'dir-printer fileentry))

(declare-function vc-only-files-state-and-model "vc")

(defun vc-dir-deduce-fileset (&optional state-model-only-files)
  (let ((marked (vc-dir-marked-files))
	files only-files-list)
    (if marked
	(progn
	  (setq files marked)
	  (when state-model-only-files
	    (setq only-files-list (vc-dir-marked-only-files-and-states))))
      (let ((crt (vc-dir-current-file)))
	(setq files (list crt))
	(when state-model-only-files
	  (setq only-files-list (vc-dir-child-files-and-states)))))
    (if state-model-only-files
        (cl-list* vc-dir-backend files
                  (vc-only-files-state-and-model only-files-list
                                                 vc-dir-backend))
      (list vc-dir-backend files))))

;;;###autoload
(defun vc-dir-root ()
  "Run `vc-dir' in the repository root directory without prompt.
If the default directory of the current buffer is
not under version control, prompt for a directory."
  (interactive)
  (let ((root-dir (vc-root-dir)))
    (if root-dir (vc-dir root-dir)
      (call-interactively 'vc-dir))))

;;;###autoload
(defun vc-dir (dir &optional backend)
  "Show the VC status for \"interesting\" files in and below DIR.
This allows you to mark files and perform VC operations on them.
The list omits files which are up to date, with no changes in your copy
or the repository, if there is nothing in particular to say about them.

Preparing the list of file status takes time; when the buffer
first appears, it has only the first few lines of summary information.
The file lines appear later.

Optional second argument BACKEND specifies the VC backend to use.
Interactively, a prefix argument means to ask for the backend.

These are the commands available for use in the file status buffer:

\\{vc-dir-mode-map}"

  (interactive
   (list
    ;; When you hit C-x v d in a visited VC file,
    ;; the *vc-dir* buffer visits the directory under its truename;
    ;; therefore it makes sense to always do that.
    ;; Otherwise if you do C-x v d -> C-x C-f -> C-x v d
    ;; you may get a new *vc-dir* buffer, different from the original
    (file-truename (read-directory-name "VC status for directory: "
					(vc-root-dir) nil t
					nil))
    (if current-prefix-arg
	(intern
	 (completing-read
	  "Use VC backend: "
	  (mapcar (lambda (b) (list (symbol-name b)))
		  vc-handled-backends)
	  nil t nil nil)))))
  (unless backend
    (setq backend (vc-responsible-backend dir)))
  (let (pop-up-windows)		      ; based on cvs-examine; bug#6204
    (pop-to-buffer (vc-dir-prepare-status-buffer "*vc-dir*" dir backend)))
  (if (derived-mode-p 'vc-dir-mode)
      (vc-dir-refresh)
    ;; FIXME: find a better way to pass the backend to `vc-dir-mode'.
    (let ((use-vc-backend backend))
      (vc-dir-mode)
      ;; Activate the backend-specific minor mode, if any.
      (when-let* ((minor-mode
                   (intern-soft (format "vc-dir-%s-mode"
                                        (downcase (symbol-name backend))))))
        (funcall minor-mode 1)))))

(defun vc-default-dir-extra-headers (_backend _dir)
  ;; Be loud by default to remind people to add code to display
  ;; backend specific headers.
  ;; XXX: change this to return nil before the release.
  (concat
   (propertize "Extra      : " 'face 'vc-dir-header)
   (propertize "Please add backend specific headers here.  It's easy!"
	       'face 'vc-dir-status-warning)))

(defvar-keymap vc-dir-status-mouse-map
  :doc "Local keymap for toggling mark."
  "<mouse-2>" #'vc-dir-toggle-mark)

(defvar-keymap vc-dir-filename-mouse-map
  :doc "Local keymap for visiting a file."
  "<mouse-2>" #'vc-dir-find-file-other-window)

(defun vc-default-dir-printer (_backend fileentry)
  "Pretty print FILEENTRY."
  ;; If you change the layout here, change vc-dir-move-to-goal-column.
  ;; VC backends can implement backend specific versions of this
  ;; function.  Changes here might need to be reflected in the
  ;; vc-BACKEND-dir-printer functions.
  (let* ((isdir (vc-dir-fileinfo->directory fileentry))
	(state (if isdir "" (vc-dir-fileinfo->state fileentry)))
	(filename (vc-dir-fileinfo->name fileentry)))
    (insert
     (propertize
      (format "%c" (if (vc-dir-fileinfo->marked fileentry) ?* ? ))
      'face 'vc-dir-mark-indicator)
     "   "
     (propertize
      (format "%-20s" state)
      'face (cond
             ((eq state 'up-to-date) 'vc-dir-status-up-to-date)
             ((memq state '(missing conflict needs-update unlocked-changes))
              'vc-dir-status-warning)
             ((eq state 'ignored) 'vc-dir-status-ignored)
             (t 'vc-dir-status-edited))
      'mouse-face 'highlight
      'keymap vc-dir-status-mouse-map)
     " "
     (propertize
      (format "%s" filename)
      'face
      (if isdir 'vc-dir-directory 'vc-dir-file)
      'help-echo
      (if isdir
	  "Directory\nVC operations can be applied to it\nmouse-3: Pop-up menu"
	"File\nmouse-3: Pop-up menu")
      'mouse-face 'highlight
      'keymap vc-dir-filename-mouse-map))))

(defun vc-default-extra-status-menu (_backend)
  nil)

(defun vc-default-status-fileinfo-extra (_backend _file)
  "Default absence of extra information returned for a file."
  nil)


;;; Support for desktop.el (adapted from what dired.el does).

(declare-function desktop-file-name "desktop" (filename dirname))

(defun vc-dir-desktop-buffer-misc-data (dirname)
  "Auxiliary information to be saved in desktop file."
  (cons (desktop-file-name default-directory dirname) vc-dir-backend))

(defvar desktop-missing-file-warning)

(defun vc-dir-restore-desktop-buffer (_filename _buffername misc-data)
  "Restore a `vc-dir' buffer specified in a desktop file."
  (let ((dir (car misc-data))
	(backend (cdr misc-data)))
    (if (file-directory-p dir)
	(progn
	  (vc-dir dir backend)
	  (current-buffer))
      (message "Desktop: Directory %s no longer exists." dir)
      (when desktop-missing-file-warning (sit-for 1))
      nil)))

(add-to-list 'desktop-buffer-mode-handlers
	     '(vc-dir-mode . vc-dir-restore-desktop-buffer))


;;; Support for bookmark.el (adapted from what info.el does).

(declare-function bookmark-make-record-default
                  "bookmark" (&optional no-file no-context posn))
(declare-function bookmark-prop-get "bookmark" (bookmark prop))
(declare-function bookmark-default-handler "bookmark" (bmk))
(declare-function bookmark-get-bookmark-record "bookmark" (bmk))

(defun vc-dir-bookmark-make-record ()
  "Make record used to bookmark a `vc-dir' buffer.
This implements the `bookmark-make-record-function' type for
`vc-dir' buffers."
  (let* ((bookmark-name
          (file-name-nondirectory
           (directory-file-name default-directory)))
         (defaults (list bookmark-name default-directory)))
    `(,bookmark-name
      ,@(bookmark-make-record-default 'no-file)
      (filename . ,default-directory)
      (handler . vc-dir-bookmark-jump)
      (defaults . ,defaults))))

;;;###autoload
(defun vc-dir-bookmark-jump (bmk)
  "Provide the `bookmark-jump' behavior for a `vc-dir' buffer.
This implements the `handler' function interface for the record
type returned by `vc-dir-bookmark-make-record'."
  (let* ((file (bookmark-prop-get bmk 'filename))
         (buf (progn ;; Don't use save-window-excursion (bug#39722)
                (vc-dir file)
                (current-buffer))))
    (bookmark-default-handler
     `("" (buffer . ,buf) . ,(bookmark-get-bookmark-record bmk)))))

(put 'vc-dir-bookmark-jump 'bookmark-handler-type "VC")


(provide 'vc-dir)

;;; vc-dir.el ends here
