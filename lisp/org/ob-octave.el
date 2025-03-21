;;; ob-octave.el --- Babel Functions for Octave and Matlab -*- lexical-binding: t; -*-

;; Copyright (C) 2010-2025 Free Software Foundation, Inc.

;; Author: Dan Davison
;; Keywords: literate programming, reproducible research
;; URL: https://orgmode.org

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

;;; Requirements:

;; octave
;; octave-mode.el and octave-inf.el come with GNU emacs

;;; Code:

(require 'org-macs)
(org-assert-version)

(require 'ob)
(require 'org-macs)

(declare-function matlab-shell "ext:matlab-mode")
(declare-function matlab-shell-run-region "ext:matlab-mode")

(defvar org-babel-default-header-args:matlab '())
(defvar org-babel-default-header-args:octave '())

(defvar org-babel-matlab-shell-command "matlab -nosplash"
  "Shell command to run matlab as an external process.")
(defvar org-babel-octave-shell-command "octave -q"
  "Shell command to run octave as an external process.")

(defvar org-babel-matlab-with-emacs-link nil
  "If non-nil use matlab-shell-run-region for session evaluation.
This will use EmacsLink if (matlab-with-emacs-link) evaluates
to a non-nil value.")

(defvar org-babel-matlab-emacs-link-wrapper-method
  "%s
if ischar(ans), fid = fopen('%s', 'w'); fprintf(fid, '%%s\\n', ans); fclose(fid);
else, save -ascii %s ans
end
delete('%s')
")
(defvar org-babel-octave-wrapper-method
  "%s
if ischar(ans), fid = fopen('%s', 'w'); fdisp(fid, ans); fclose(fid);
else, dlmwrite('%s', ans, '\\t')
end")

(defvar org-babel-octave-eoe-indicator "'org_babel_eoe'")

(defvar org-babel-octave-eoe-output "ans = org_babel_eoe")

(defun org-babel-execute:matlab (body params)
  "Execute Matlab BODY according to PARAMS."
  (org-babel-execute:octave body params 'matlab))

(defun org-babel-execute:octave (body params &optional matlabp)
  "Execute Octave or Matlab BODY according to PARAMS.
When MATLABP is non-nil, execute Matlab.  Otherwise, execute Octave."
  (let* ((session
	  (funcall (intern (format "org-babel-%s-initiate-session"
				   (if matlabp "matlab" "octave")))
		   (cdr (assq :session params)) params))
         (result-type (cdr (assq :result-type params)))
	 (full-body
	  (org-babel-expand-body:generic
	   body params (org-babel-variable-assignments:octave params)))
	 (gfx-file (ignore-errors (org-babel-graphical-output-file params)))
	 (result (org-babel-octave-evaluate
		  session
		  (if gfx-file
		      (mapconcat 'identity
				 (list
				  "set (0, \"defaultfigurevisible\", \"off\");"
				  full-body
				  (format "print -dpng %S\nans=%S" gfx-file gfx-file))
				 "\n")
		    full-body)
		  result-type matlabp)))
    (if gfx-file
	nil
      (org-babel-reassemble-table
       result
       (org-babel-pick-name
	(cdr (assq :colname-names params)) (cdr (assq :colnames params)))
       (org-babel-pick-name
	(cdr (assq :rowname-names params)) (cdr (assq :rownames params)))))))

(defun org-babel-prep-session:matlab (session params)
  "Prepare SESSION according to PARAMS."
  (org-babel-prep-session:octave session params 'matlab))

(defun org-babel-variable-assignments:octave (params)
  "Return list of octave statements assigning the block's variables.
The variables are taken from PARAMS."
  (mapcar
   (lambda (pair)
     (format "%s=%s;"
	     (car pair)
	     (org-babel-octave-var-to-octave (cdr pair))))
   (org-babel--get-vars params)))

(defalias 'org-babel-variable-assignments:matlab
  'org-babel-variable-assignments:octave)

(defun org-babel-octave-var-to-octave (value)
  "Convert an emacs-lisp VALUE into an octave variable.
Converts an emacs-lisp variable into a string of octave code
specifying a variable of the same value."
  (if (listp value)
      (concat "[" (mapconcat #'org-babel-octave-var-to-octave value
			     (if (listp (car value)) "; " ",")) "]")
    (cond
     ((stringp value)
      (format "'%s'" value))
     (t
      (format "%s" value)))))

(defun org-babel-prep-session:octave (session params &optional matlabp)
  "Prepare SESSION according to the header arguments specified in PARAMS.
The session will be an Octave session, unless MATLABP is non-nil."
  (let* ((session (org-babel-octave-initiate-session session params matlabp))
	 (var-lines (org-babel-variable-assignments:octave params)))
    (org-babel-comint-in-buffer session
      (mapc (lambda (var)
              (end-of-line 1) (insert var) (comint-send-input nil t)
              (org-babel-comint-wait-for-output session))
	    var-lines))
    session))

(defun org-babel-matlab-initiate-session (&optional session params)
  "Create a matlab inferior process buffer.
If there is not a current inferior-process-buffer in SESSION then
create.  Return the initialized session.  PARAMS are src block parameters."
  (org-babel-octave-initiate-session session params 'matlab))

(defun org-babel-octave-initiate-session (&optional session _params matlabp)
  "Create an octave inferior process buffer.
If there is not a current inferior-process-buffer in SESSION then
create.  Return the initialized session.  The session will be an
Octave session, unless MATLABP is non-nil."
  (if matlabp
      (org-require-package 'matlab "matlab-mode")
    (or (require 'octave-inf nil 'noerror)
	(require 'octave)))
  (unless (string= session "none")
    (let ((session (or session
		       (if matlabp "*Inferior Matlab*" "*Inferior Octave*"))))
      (if (org-babel-comint-buffer-livep session) session
	(save-window-excursion
	  (if matlabp (unless org-babel-matlab-with-emacs-link (matlab-shell))
	    (run-octave))
	  (rename-buffer (if (bufferp session) (buffer-name session)
			   (if (stringp session) session (buffer-name))))
	  (current-buffer))))))

(defun org-babel-octave-evaluate
    (session body result-type &optional matlabp)
  "Pass BODY to the octave process in SESSION.
If RESULT-TYPE equals `output' then return the outputs of the
statements in BODY, if RESULT-TYPE equals `value' then return the
value of the last statement in BODY, as elisp."
  (if session
      (org-babel-octave-evaluate-session session body result-type matlabp)
    (org-babel-octave-evaluate-external-process body result-type matlabp)))

(defun org-babel-octave-evaluate-external-process (body result-type matlabp)
  "Evaluate BODY in an external Octave or Matalab process.
Process the result as RESULT-TYPE.  Use Octave, unless MATLABP is non-nil."
  (let ((cmd (if matlabp
		 org-babel-matlab-shell-command
	       org-babel-octave-shell-command)))
    (pcase result-type
      (`output (org-babel-eval cmd body))
      (`value (let ((tmp-file (org-babel-temp-file "octave-")))
	        (org-babel-eval
		 cmd
		 (format org-babel-octave-wrapper-method body
			 (org-babel-process-file-name tmp-file 'noquote)
			 (org-babel-process-file-name tmp-file 'noquote)))
	        (org-babel-octave-import-elisp-from-file tmp-file))))))

(defun org-babel-octave-evaluate-session
    (session body result-type &optional matlabp)
  "Evaluate BODY in SESSION."
  (let* ((tmp-file (org-babel-temp-file (if matlabp "matlab-" "octave-")))
	 (wait-file (org-babel-temp-file "matlab-emacs-link-wait-signal-"))
	 (full-body
	  (pcase result-type
	    (`output
	     (mapconcat
	      #'org-babel-chomp
	      (list body org-babel-octave-eoe-indicator) "\n"))
	    (`value
	     (if (and matlabp org-babel-matlab-with-emacs-link)
		 (concat
		  (format org-babel-matlab-emacs-link-wrapper-method
			  body
			  (org-babel-process-file-name tmp-file 'noquote)
			  (org-babel-process-file-name tmp-file 'noquote) wait-file) "\n")
	       (mapconcat
		#'org-babel-chomp
		(list (format org-babel-octave-wrapper-method
			      body
			      (org-babel-process-file-name tmp-file 'noquote)
			      (org-babel-process-file-name tmp-file 'noquote))
		      org-babel-octave-eoe-indicator) "\n")))))
	 (raw (if (and matlabp org-babel-matlab-with-emacs-link)
		  (save-window-excursion
		    (with-temp-buffer
		      (insert full-body)
		      (write-region "" 'ignored wait-file nil nil nil 'excl)
		      (matlab-shell-run-region (point-min) (point-max))
		      (message "Waiting for Matlab Emacs Link")
		      (while (file-exists-p wait-file) (sit-for 0.01))
		      "")) ;; matlab-shell-run-region doesn't seem to
		;; make *matlab* buffer contents easily
		;; available, so :results output currently
		;; won't work
		(org-babel-comint-with-output
		    (session
		     (if matlabp
			 org-babel-octave-eoe-indicator
		       org-babel-octave-eoe-output)
		     t full-body)
		  (insert full-body) (comint-send-input nil t))))
	 results)
    (pcase result-type
      (`value
       (org-babel-octave-import-elisp-from-file tmp-file))
      (`output
       (setq results
	     (if matlabp
		 (cdr (reverse (delete "" (mapcar #'org-strip-quotes
					          (mapcar #'org-trim raw)))))
	       (cdr (member org-babel-octave-eoe-output
			    (reverse (mapcar #'org-strip-quotes
					     (mapcar #'org-trim raw)))))))
       (mapconcat #'identity (reverse results) "\n")))))

(defun org-babel-octave-import-elisp-from-file (file-name)
  "Import data from FILE-NAME.
This removes initial blank and comment lines and then calls
`org-babel-import-elisp-from-file'."
  (let ((temp-file (org-babel-temp-file "octave-matlab-")) beg end)
    (with-temp-file temp-file
      (insert-file-contents file-name)
      (re-search-forward "^[ \t]*[^# \t]" nil t)
      (when (< (setq beg (point-min))
               (setq end (line-beginning-position)))
	(delete-region beg end)))
    (org-babel-import-elisp-from-file temp-file '(16))))

(provide 'ob-octave)

;;; ob-octave.el ends here
