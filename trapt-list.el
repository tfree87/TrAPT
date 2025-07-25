;;; trapt-list.el --- Interact with APT List -*- lexical-binding: t -*-

;; Author: Thomas Freeman
;; Maintainer: Thomas Freeman
;; Version: 20250522
;; Package-Requires: ((emacs "24.4"))
;; Homepage: https://github.com/tfree87/trapt
;; Keywords: processes


;; This file is not part of GNU Emacs

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


;;; Commentary:

;; This package is part of TrAPT. This package provides features to
;; pipe the output of APT list to a tabulated list buffer. Packages can
;; be marked and then APT commands can be executed on the selection.

;;; Code:

(require 'easymenu)
(require 'tablist)
(require 'trapt-utils)

(defgroup trapt-list nil
  "TrAPT preferences for working with APT list."
  :group 'TrAPT
  :prefix "trapt-list-")

(defcustom trapt-list-default-sort-key '("Name" . nil)
  "Sort key for for sorting results returned from apt list.

This should be a cons cell (NAME . FLIP) where NAME is a string matching one of
the column names from `trapt-list--columns' and FLIP is a boolean to specify
the sort order."
  :group 'trapt-list
  :type '(cons (string :tag "Column Name"
                       :validate (lambda (widget)
                                   (unless (member
                                            (widget-value widget)
                                            trapt-list--columns)
                                     (widget-put widget
                                                 (error "Default Sort Key must\
 match a column name"))
                                     widget)))
               (choice (const :tag "Ascending" nil)
                       (const :tag "Descending" t))))

(defvar trapt-list--current-command nil
  "The command used to generate the current list.")

(defvar trapt-list--tabulated-list-format [("Name" 30 t)
                                           ("Source" 25 t)
                                           ("Version" 15 t)
                                           ("Architecture" 8 t)
                                           ("Status" 50 t (:right-align t))]
  "The `tabulated-list-format' for TrAPT List buffers.")

(defvar trapt-list-mode-map
  (let ((map (make-sparse-keymap)))
    (when (fboundp #'trapt)
      (define-key map "a" #'trapt-org-export-all)
      (define-key map "m" #'trapt-org-export-marked)
      (define-key map "x" #'trapt))
    map)
  "Keymap for `trapt-list-mode'.")

(defvar trapt-list--columns '("Name" "Version" "Architecture" "Status")
  "A list of column names for `trapt-list-mode'.")

(defvar trapt-list--buffer-name "*APT List*"
  "The name of the buffer created for APT List Mode.")

(defvar trapt-list--mode-name "TrAPT List"
  "The name of `trapt-list-mode' buffer.")

(defvar trapt-list--num-installed nil
  "The number of installed APT packages.")

(defvar trapt-list--num-upgradable nil
  "The number of upgradable APT packages.")

(defvar trapt-list--num-residual nil
  "The number of APT packages with residual data.")

(defvar trapt-list--num-auto-intalled nil
  "The number of automatically installed APT packages.")

(defvar trapt-list--entries nil
  "A list of all the APT List entries for `tabulated-list-entries'.")

(easy-menu-define trapt-list-mode-menu trapt-list-mode-map
  "Menu when `trapt-list-mode' is active."
  `("TrAPT List"
    ["Install selected packages" trapt-apt-install
     :help "Install the selected packages with APT."]
    ["Purge selected packages" trapt-apt-purge
     :help "Purge selected packages with APT."]
    ["Reinstall selected packages" trapt-apt-reinstall
     :help "Reinstall selected packages with APT."]
    ["Reinstall selected packages" trapt-apt-remove
     :help "Remove selected packages with APT."]))

(defun trapt-list--get-stats ()
  "Return a list of statistics from APT list."
  (thread-last
    (cl-loop for element in tabulated-list-entries
             when  (string-match "upgradable" (aref (cadr element) 4))
             count element into num-upgradable
             when (string-match "installed" (aref (cadr element) 4))
             count element into num-installed
             when (string-match "residual-config" (aref (cadr element) 4))
             count element into num-residual
             when (string-match "automatic" (aref (cadr element) 4))
             count element into num-auto
             finally
             return
             (if (not (string-match "--upgradable" trapt-list--current-command))
                 (cl-values `(trapt-list--num-installed . ,num-installed)
                            `(trapt-list--num-upgradable . ,num-upgradable)
                            `(trapt-list--num-residual . ,num-residual)
                            `(trapt-list--num-auto-installed . ,num-auto))
               ;; Only update upgradable stat if that list is called
               (cl-values`(trapt-list--num-upgradable . ,num-upgradable))))
    (trapt-utils--set-save-stats)))

(defun trapt-list--create-tablist (command &optional server)
  "Call `trapt-list--apt-list-to-tablist' and create a tablist buffer.

The buffer contains the result of `apt list' run from in an inferior shell.

COMMAND must be a string with the form `sudo apt list [arguments]'.

SERVER is a string of the form username@server that specifies a server on which
to run the command."
  (cl-labels
      ((add-trapt-list--buffer-name-to-trapt-list--tablist-buffers ()
         "Add `trapt-list--buffer-name' to `trapt--tablist-buffers'."
         (when (boundp 'trapt--tablist-buffers)
           (if trapt--tablist-buffers
               (add-to-list 'trapt--tablist-buffers
                            trapt-list--buffer-name)
             (push trapt-list--buffer-name trapt--tablist-buffers))))
       
       (remove-unwanted-lines (apt-lines-list)
         "Remove unwanted messages from APT-LINES-LIST."
         (cl-remove-if (lambda (item)
                         (or (string-empty-p item)
                             (string-prefix-p "N:" item)
                             (string-prefix-p "WARNING:" item)
                             (string-prefix-p "Listing" item)
                             (string-prefix-p "Listing..." item)))
                       apt-lines-list))
       
       (apt-output-to-list (apt-output)
         "Split APT-OUTPUT string to a list and removed unwanted lines."
         (thread-last
           (split-string apt-output "\n")
           (remove-unwanted-lines)
           (mapcar #'(lambda (item) (split-string item  "[ /]")))))
       
       (lines-to-entries (apt-output-list)
         "Convert each line from APT-LINES list to an entry"
         (cl-loop for line in apt-output-list
                  for counter from 1
                  collect (if (= (length line) 4)
                              `(,counter [,@line "none"])
                            `(,counter [,@line])))))

    (setf trapt-list--current-command command)
    (with-current-buffer (get-buffer-create trapt-list--buffer-name)
      (trapt-list-mode)
      (add-trapt-list--buffer-name-to-trapt-list--tablist-buffers)
      (setf tabulated-list-format trapt-list--tabulated-list-format)
      (setf tabulated-list-sort-key trapt-list-default-sort-key)
      (tabulated-list-init-header)
      (thread-last
        (trapt-utils--shell-command-to-string command server)
        (apt-output-to-list)
        (lines-to-entries)
        (setf trapt-list--entries)
        (setf tabulated-list-entries))
      (revert-buffer))
    (switch-to-buffer trapt-list--buffer-name)))

;;;###autoload
(define-derived-mode trapt-list-mode tabulated-list-mode trapt-list--mode-name
  "Major mode for interacting with a list of packages from APT."
  :keymap trapt-list-mode-map
  (setf tabulated-list-padding 2)
  (tablist-minor-mode))

(provide 'trapt-list)

;;; trapt-list.el ends here
