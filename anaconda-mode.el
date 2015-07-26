;;; anaconda-mode.el --- Code navigation, documentation lookup and completion for Python  -*- lexical-binding: t; -*-

;; Copyright (C) 2013-2015 by Artem Malyshev

;; Author: Artem Malyshev <proofit404@gmail.com>
;; URL: https://github.com/proofit404/anaconda-mode
;; Version: 0.1.0
;; Package-Requires: ((emacs "24") (cl-lib "0.5.0") (pythonic "0.1.0") (dash "2.6.0") (s "1.9") (f "0.16.2"))


;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; See the README for more details.

;;; Code:

(require 'cl-lib)
(require 'tramp)
(require 'url)
(require 'json)
(require 'pythonic)
(require 'dash)
(require 's)
(require 'f)

(defgroup anaconda-mode nil
  "Code navigation, documentation lookup and completion for Python."
  :group 'programming)

(defcustom anaconda-eldoc-as-single-line nil
  "If not nil, trim eldoc string to frame width."
  :group 'anaconda-mode
  :type 'boolean)


;;; Server.

(defvar anaconda-mode-server-version "0.1.1"
  "Server version needed to run anaconda-mode.")

(defvar anaconda-mode-server-directory
  (f-join "~" ".emacs.d" "anaconda-mode" anaconda-mode-server-version)
  "Anaconda mode installation directory.")

(defvar anaconda-mode-server-script "anaconda_mode.py"
  "Script file with anaconda-mode server.")

(defvar anaconda-mode-process-name "anaconda-mode"
  "Process name for anaconda-mode processes.")

(defvar anaconda-mode-process-buffer "*anaconda-mode*"
  "Buffer name for anaconda-mode processes.")

(defvar anaconda-mode-process nil
  "Currently running anaconda-mode process.")

(defun anaconda-mode-start ()
  "Start anaconda-mode server."
  (when (anaconda-mode-need-restart)
    (anaconda-mode-stop))
  (unless (anaconda-mode-running-p)
    (anaconda-mode-ensure-directory)))

(defun anaconda-mode-stop ()
  "Stop anaconda-mode server."
  (when (anaconda-mode-running-p)
    (set-process-filter anaconda-mode-process nil)
    (set-process-sentinel anaconda-mode-process nil)
    (kill-process anaconda-mode-process)
    (setq anaconda-mode-process nil
          anaconda-mode-port nil)))

(defun anaconda-mode-running-p ()
  "Is `anaconda-mode' server running."
  (and anaconda-mode-process
       (process-live-p anaconda-mode-process)))

(defun anaconda-mode-need-restart ()
  "Check if current `anaconda-mode-process' need restart with new args.
Return nil if it run under proper environment."
  (when (anaconda-mode-running-p)
    (not (and
          (equal
           (pythonic-executable)
           (car (process-command anaconda-mode-process)))
          (equal
           (pythonic-default-directory anaconda-mode-server-directory)
           (process-get anaconda-mode-process 'default-directory))
          (equal
           (pythonic-get-pythonpath)
           (process-get anaconda-mode-process 'pythonpath))
          (equal
           (pythonic-get-path)
           (process-get anaconda-mode-process 'path))
          (equal
           python-shell-process-environment
           (process-get anaconda-mode-process 'environment))))))

(defun anaconda-mode-ensure-directory ()
  "Ensure if `anaconda-mode-server-directory' exists."
  (setq anaconda-mode-process
        (start-pythonic :process anaconda-mode-process-name
                        :buffer anaconda-mode-process-buffer
                        :sentinel 'anaconda-mode-ensure-directory-sentinel
                        :args (list "-c" "
import os
import sys
directory = sys.argv[1]
if not os.path.exists(directory):
    os.makedirs(directory)
" anaconda-mode-server-directory))))

(defun anaconda-mode-ensure-directory-sentinel (process event)
  "Run `anaconda-mode-check' if `anaconda-mode-server-directory' exists.
Raise error otherwise.  PROCESS and EVENT are basic sentinel
parameters."
  (if (eq 0 (process-exit-status process))
      (anaconda-mode-check)
    (pop-to-buffer anaconda-mode-process-buffer)
    (error "Can't create %s directory" anaconda-mode-server-directory)))

(defun anaconda-mode-check ()
  "Check `anaconda-mode' server installation."
  (setq anaconda-mode-process
        (start-pythonic :process anaconda-mode-process-name
                        :buffer anaconda-mode-process-buffer
                        :cwd anaconda-mode-server-directory
                        :sentinel 'anaconda-mode-check-sentinel
                        :args '("-c" "
from pkg_resources import get_distribution
def check_deps(deps=['anaconda_mode']):
    for each in deps:
        distrib = get_distribution(each)
        requirements = distrib.requires()
        check_deps(requirements)
check_deps()
"))))

(defun anaconda-mode-check-sentinel (process event)
  "Run `anaconda-mode-bootstrap' if server installation check passed.
Try to install `anaconda-mode' server otherwise.  PROCESS and
EVENT are basic sentinel parameters."
  (if (eq 0 (process-exit-status process))
      (anaconda-mode-bootstrap)
    (anaconda-mode-install)))

(defun anaconda-mode-install ()
  "Try to install `anaconda-mode' server."
  (setq anaconda-mode-process
        (start-pythonic :process anaconda-mode-process-name
                        :buffer anaconda-mode-process-buffer
                        :cwd anaconda-mode-server-directory
                        :sentinel 'anaconda-mode-install-sentinel
                        :args (list "-m" "pip" "install" "-t" "."
                                    (concat "anaconda_mode" "=="
                                            anaconda-mode-server-version)))))

(defun anaconda-mode-install-sentinel (process event)
  "Run `anaconda-mode-bootstrap' if server installation complete successfully.
Raise error otherwise.  PROCESS and EVENT are basic sentinel
parameters."
  (if (eq 0 (process-exit-status process))
      (anaconda-mode-bootstrap)
    (pop-to-buffer anaconda-mode-process-buffer)
    (error "Can't install `anaconda-mode' server")))

(defun anaconda-mode-bootstrap ()
  "Run `anaconda-mode' server."
  (setq anaconda-mode-process
        (start-pythonic :process anaconda-mode-process-name
                        :buffer anaconda-mode-process-buffer
                        :cwd anaconda-mode-server-directory
                        :filter 'anaconda-mode-bootstrap-filter
                        :sentinel 'anaconda-mode-bootstrap-sentinel
                        :query-on-exit nil
                        :args (list anaconda-mode-server-script))))

(defun anaconda-mode-bootstrap-filter (process output)
  "Set `anaconda-mode-port' from PROCESS OUTPUT.
Connect to the `anaconda-mode' server."
  ;; Mimic default filter.
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (save-excursion
        (goto-char (process-mark process))
        (insert output)
        (set-marker (process-mark process) (point)))))
  (--when-let (s-match "anaconda_mode port \\([0-9]+\\)" output)
    (setq anaconda-mode-port (string-to-number (cadr it)))
    (set-process-filter process nil)
    ;; (anaconda-mode-json-rpc)
    ))

(defun anaconda-mode-bootstrap-sentinel (process event)
  "Raise error if `anaconda-mode' server exit abnormally.
PROCESS and EVENT are basic sentinel parameters."
  (unless (eq 0 (process-exit-status process))
    (pop-to-buffer anaconda-mode-process-buffer)
    (error "Can't start `anaconda-mode' server")))


;;; Connection.

(defun anaconda-mode-host ()
  "Target host with anaconda-mode server."
  (if (pythonic-remote-p)
      (tramp-file-name-host
       (tramp-dissect-file-name
        (pythonic-tramp-connection)))
    "127.0.0.1"))

(defvar anaconda-mode-port nil
  "Port for anaconda-mode connection.")

(defun anaconda-mode-bound-p ()
  "Is `anaconda-mode' port bound."
  (numberp anaconda-mode-port))

(defun anaconda-mode-json-rpc ()
  "Perform JSON-RPC call."
  (let ((url-request-method "POST")
        (url-request-data
         (json-encode
          (vector
           command
           (buffer-substring-no-properties (point-min) (point-max))
           (line-number-at-pos (point))
           (- (point) (line-beginning-position))
           (pythonic-file-name (buffer-file-name))))))
    (url-retrieve
     (format "http://%s:%s" (anaconda-mode-host) anaconda-mode-port)
     callback)))


;;; Interaction.

(defun anaconda-mode-call (command callback)
  "Make remote procedure call for COMMAND.
Apply CALLBACK to it result."
  (anaconda-mode-start)
  (when (anaconda-mode-connected-p)
    (anaconda-mode-json-rpc)))


;;; Code completion.

(defun anaconda-mode-complete-at-point ()
  "Complete at point with anaconda-mode."
  (let* ((bounds (bounds-of-thing-at-point 'symbol))
         (start (or (car bounds) (point)))
         (stop (or (cdr bounds) (point))))
    (list start stop
          (completion-table-dynamic
           'anaconda-mode-complete-thing))))

(defun anaconda-mode-complete-thing (&rest ignored)
  "Complete python thing at point.
Do nothing in comments block.
IGNORED parameter is the string for which completion is required."
  (unless (python-syntax-comment-or-string-p)
    (--map (plist-get it :name)
           (anaconda-mode-complete))))

(defun anaconda-mode-complete ()
  "Request completion candidates."
  (anaconda-mode-call "complete"))


;;; View documentation.

(defun anaconda-mode-view-doc ()
  "Show documentation for context at point."
  (interactive)
  (pop-to-buffer
   (anaconda-mode-doc-buffer
    (or (anaconda-mode-call "doc")
        (error "No documentation found")))))

(defun anaconda-mode-doc-buffer (doc)
  "Display documentation buffer with contents DOC."
  (let ((buf (get-buffer-create "*anaconda-doc*")))
    (with-current-buffer buf
      (view-mode -1)
      (erase-buffer)
      (insert doc)
      (goto-char (point-min))
      (view-mode 1)
      buf)))


;;; Usages.

(defun anaconda-mode-usages ()
  "Show usages for thing at point."
  (interactive)
  (anaconda-nav-navigate
   (or (anaconda-mode-call "usages")
       (error "No usages found"))))


;;; Definitions and assignments.

(defun anaconda-mode-goto-definitions ()
  "Goto definition for thing at point."
  (interactive)
  (anaconda-nav-navigate
   (or (anaconda-mode-call "goto_definitions")
       (error "No definition found"))
   t))

(defun anaconda-mode-goto-assignments ()
  "Goto assignment for thing at point."
  (interactive)
  (anaconda-nav-navigate
   (or (anaconda-mode-call "goto_assignments")
       (error "No assignment found"))
   t))

(defun anaconda-mode-goto ()
  "Goto definition or fallback to assignment for thing at point."
  (interactive)
  (anaconda-nav-navigate
   (or (anaconda-mode-call "goto_definitions")
       (anaconda-mode-call "goto_assignments")
       (error "No definition found"))
   t))


;;; Anaconda navigator mode

(defvar anaconda-nav--last-marker nil)
(defvar anaconda-nav--markers ())

(defun anaconda-nav-pop-marker ()
  "Switch to buffer of most recent marker."
  (interactive)
  (unless anaconda-nav--markers
    (error "No marker available"))
  (let* ((marker (pop anaconda-nav--markers))
         (buffer (marker-buffer marker)))
    (unless (buffer-live-p buffer)
      (error "Buffer no longer available"))
    (switch-to-buffer buffer)
    (goto-char (marker-position marker))
    (set-marker marker nil)
    (anaconda-nav--cleanup-buffers)))

(defun anaconda-nav--push-last-marker ()
  "Add last marker to markers."
  (when (markerp anaconda-nav--last-marker)
    (push anaconda-nav--last-marker anaconda-nav--markers)
    (setq anaconda-nav--last-marker nil)))

(defun anaconda-nav--all-markers ()
  "Markers including last-marker."
  (if anaconda-nav--last-marker
      (cons anaconda-nav--last-marker anaconda-nav--markers)
    anaconda-nav--markers))

(defvar anaconda-nav--window-configuration nil)
(defvar anaconda-nav--created-buffers ())

(defun anaconda-nav--cleanup-buffers ()
  "Kill unmodified buffers (without markers) created by anaconda-nav."
  (let* ((marker-buffers (-map 'marker-buffer (anaconda-nav--all-markers)))
         (result (--separate (-contains? marker-buffers it)
                             anaconda-nav--created-buffers)))
    (setq anaconda-nav--created-buffers (car result))
    (-each (cadr result) 'kill-buffer-if-not-modified)))

(defun anaconda-nav--get-or-create-buffer (path)
  "Get buffer for PATH, and record if buffer was created."
  (or (find-buffer-visiting path)
      (let ((created-buffer (find-file-noselect path)))
        (anaconda-nav--cleanup-buffers)
        (push created-buffer anaconda-nav--created-buffers)
        created-buffer)))

(defun anaconda-nav--restore-window-configuration ()
  "Restore window configuration."
  (when anaconda-nav--window-configuration
    (set-window-configuration anaconda-nav--window-configuration)
    (setq anaconda-nav--window-configuration nil)))

(defun anaconda-nav-navigate (result &optional goto-if-single-item)
  "Navigate RESULT, jump if only one item and GOTO-IF-SINGLE-ITEM is non-nil."
  (setq anaconda-nav--last-marker (point-marker))
  (if (and goto-if-single-item (= 1 (length result)))
      (progn (anaconda-nav--push-last-marker)
             (switch-to-buffer (anaconda-nav--item-buffer (car result))))
    (setq anaconda-nav--window-configuration (current-window-configuration))
    (delete-other-windows)
    (switch-to-buffer-other-window (anaconda-nav--prepare-buffer result))))

(defun anaconda-nav--prepare-buffer (result)
  "Render RESULT in the navigation buffer."
  (with-current-buffer (get-buffer-create "*anaconda-nav*")
    (setq buffer-read-only nil)
    (erase-buffer)
    (setq-local overlay-arrow-position nil)
    (--> result
         (--group-by (cons (plist-get it :module)
                           (plist-get it :path)) it)
         (--each it (apply 'anaconda-nav--insert-module it)))
    (goto-char (point-min))
    (anaconda-nav-mode)
    (current-buffer)))

(defun anaconda-nav--insert-module (header &rest items)
  "Insert a module consisting of a HEADER with ITEMS."
  (insert (propertize (car header)
                      'face 'bold
                      'anaconda-nav-module t)
          "\n")
  (--each items (insert (anaconda-nav--format-item it) "\n"))
  (insert "\n"))

(defun anaconda-nav--format-item (item)
  "Format ITEM as a row."
  (propertize
   (concat (propertize (format "%7d " (plist-get item :line))
                       'face 'compilation-line-number)
           (anaconda-nav--get-item-description item))
   'anaconda-nav-item item
   'follow-link t
   'mouse-face 'highlight))

(defun anaconda-nav--get-item-description (item)
  "Format description of ITEM."
  (cl-destructuring-bind (&key column name description type &allow-other-keys) item
    (cond ((string= type "module") "«module definition»")
          (t (let ((to (+ column (length name))))
               (when (string= name (substring description column to))
                 (put-text-property column to 'face 'highlight description))
               description)))))

(defun anaconda-nav-next-error (&optional argp reset)
  "Move to the ARGP'th next match, searching from start if RESET is non-nil."
  (interactive "p")
  (with-current-buffer (get-buffer "*anaconda-nav*")
    (goto-char (cond (reset (point-min))
                     ((cl-minusp argp) (line-beginning-position))
                     ((cl-plusp argp) (line-end-position))
                     ((point))))

    (--dotimes (abs argp)
      (anaconda-nav--goto-property 'anaconda-nav-item (cl-plusp argp)))

    (setq-local overlay-arrow-position (copy-marker (line-beginning-position)))
    (--when-let (get-text-property (point) 'anaconda-nav-item)
      (pop-to-buffer (anaconda-nav--item-buffer it)))))

(defun anaconda-nav--goto-property (prop forwardp)
  "Goto next property PROP in direction FORWARDP."
  (--if-let (anaconda-nav--find-property prop forwardp)
      (goto-char it)
    (error "No more matches")))

(defun anaconda-nav--find-property (prop forwardp)
  "Find next property PROP in direction FORWARDP."
  (let ((search (if forwardp #'next-single-property-change
                  #'previous-single-property-change)))
    (-when-let (pos (funcall search (point) prop))
      (if (get-text-property pos prop) pos
        (funcall search pos prop)))))

(defun anaconda-nav--item-buffer (item)
  "Get buffer of ITEM and position the point."
  (cl-destructuring-bind (&key line column name path &allow-other-keys) item
    (with-current-buffer (anaconda-nav--get-or-create-buffer path)
      (goto-char (point-min))
      (forward-line (1- line))
      (forward-char column)
      (anaconda-nav--highlight name)
      (current-buffer))))

(defun anaconda-nav--highlight (name)
  "Highlight NAME or line at point."
  (isearch-highlight (point)
                     (if (string= (symbol-at-point) name)
                         (+ (point) (length name))
                       (point-at-eol)))
  (run-with-idle-timer 0.5 nil 'isearch-dehighlight))

(defvar anaconda-nav-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-2] 'anaconda-nav-goto-item)
    (define-key map (kbd "RET") 'anaconda-nav-goto-item)
    (define-key map (kbd "n") 'next-error)
    (define-key map (kbd "p") 'previous-error)
    (define-key map (kbd "N") 'anaconda-nav-next-module)
    (define-key map (kbd "P") 'anaconda-nav-previous-module)
    (define-key map (kbd "q") 'anaconda-nav-quit)
    map)
  "Keymap for `anaconda-nav-mode'.")

(defun anaconda-nav-next-module ()
  "Visit first error of next module."
  (interactive)
  (anaconda-nav--goto-property 'anaconda-nav-module t)
  (next-error))

(defun anaconda-nav-previous-module ()
  "Visit first error of previous module."
  (interactive)
  (anaconda-nav--goto-property 'anaconda-nav-item nil)
  (anaconda-nav--goto-property 'anaconda-nav-module nil)
  (next-error))

(defun anaconda-nav-quit ()
  "Quit `anaconda-nav-mode' and restore window configuration."
  (interactive)
  (quit-window)
  (anaconda-nav--restore-window-configuration))

(defun anaconda-nav-goto-item (&optional event)
  "Go to the location of the item from EVENT."
  (interactive (list last-input-event))
  (when event (goto-char (posn-point (event-end event))))
  (-when-let (buffer (anaconda-nav-next-error 0))
    (anaconda-nav--restore-window-configuration)
    (anaconda-nav--push-last-marker)
    (switch-to-buffer buffer)))

(define-derived-mode anaconda-nav-mode special-mode "anaconda-nav"
  "Major mode for navigating a list of source locations."
  (use-local-map anaconda-nav-mode-map)
  (setq next-error-function 'anaconda-nav-next-error)
  (setq next-error-last-buffer (current-buffer))
  (next-error-follow-minor-mode 1))


;;; Eldoc.

(defun anaconda-eldoc-format-params (args index)
  "Build colorized ARGS string with current arg pointed to INDEX."
  (apply
   'concat
   (->> args
        (--map-indexed
         (if (= index it-index)
             (propertize it 'face 'eldoc-highlight-function-argument)
           it))
        (-interpose ", "))))

(cl-defun anaconda-eldoc-format (&key name index params)
  (concat
   (propertize name 'face 'font-lock-function-name-face)
   "("
   (anaconda-eldoc-format-params params index)
   ")"))

(defun anaconda-eldoc-function ()
  "Show eldoc for context at point."
  (ignore-errors
    (-when-let* ((res (anaconda-mode-call "eldoc"))
                 (doc (apply 'anaconda-eldoc-format res)))
      (if anaconda-eldoc-as-single-line
          (substring doc 0 (min (frame-width) (length doc)))
        doc))))


;;; Anaconda minor mode.

(defvar anaconda-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "M-?") 'anaconda-mode-view-doc)
    (define-key map (kbd "M-r") 'anaconda-mode-usages)
    (define-key map [remap find-tag] 'anaconda-mode-goto)
    (define-key map [remap pop-tag-mark] 'anaconda-nav-pop-marker)
    map)
  "Keymap for `anaconda-mode'.")

;;;###autoload
(define-minor-mode anaconda-mode
  "Code navigation, documentation lookup and completion for Python.

\\{anaconda-mode-map}"
  :lighter " Anaconda"
  :keymap anaconda-mode-map
  (if anaconda-mode
      (turn-on-anaconda-mode)
    (turn-off-anaconda-mode)))

(defun turn-on-anaconda-mode ()
  "Turn on `anaconda-mode'."
  (add-hook 'completion-at-point-functions
            'anaconda-mode-complete-at-point nil t)
  (make-local-variable 'eldoc-documentation-function)
  (setq-local eldoc-documentation-function 'anaconda-eldoc-function))

(defun turn-off-anaconda-mode ()
  "Turn off `anaconda-mode'."
  (remove-hook 'completion-at-point-functions
               'anaconda-mode-complete-at-point t)
  (kill-local-variable 'eldoc-documentation-function))

(provide 'anaconda-mode)

;;; anaconda-mode.el ends here
