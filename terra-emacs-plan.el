;;; terra-emacs-plan.el --- diff, plan, apply -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `terra-emacs-plan' diffs a desired state against the live Emacs and
;; returns the steps that converge it, as data; `terra-emacs-apply'
;; performs them (or, with DRY-RUN, only returns them).  Applying the
;; same state twice plans nothing the second time.  A step is a plist:
;;
;;   (:op levels :levels L)          declare the levels
;;   (:op kill :ws NAME)             a workspace the state does not name
;;   (:op rename :ws OLD :to NEW)    same id, new name
;;   (:op create :ws NAME :id ID)
;;   (:op id :ws NAME :id ID)        adopt the state's id
;;   (:op level :ws NAME :level L)
;;   (:op parameters :ws NAME :parameters ((PARAM . VALUE) ...))
;;   (:op move :ws NAME :to INDEX)
;;   (:op layout :ws NAME :layout TREE :why missing|differs|stale)
;;   (:op select :ws NAME)
;;
;; Workspaces match by id first, then by name.  A layout is rebuilt only
;; when its shape or a leaf differs, or a leaf's process died; leaf
;; handlers reuse a live buffer, so processes start only where missing.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-backend)
(require 'terra-emacs-layout)
(require 'terra-emacs-capture)

(defun terra-emacs-plan--state (state)
  "STATE, read from the file it names when it is a string."
  (if (stringp state) (terra-emacs-read-state state) state))

(defun terra-emacs-plan--actual (backend)
  "BACKEND's workspaces as (:name :id :level) plists, changing nothing."
  (mapcar (lambda (name)
            (list :name name :id (terra-emacs-backend-id backend name)
                  :level (terra-emacs-backend-level backend name)
                  :parameters (terra-emacs-backend-parameters backend name)))
          (terra-emacs-backend-workspaces backend)))

(defun terra-emacs-plan--match (desired actual)
  "Pair each DESIRED workspace with an ACTUAL one: ((D . A-or-nil) ...)."
  (let ((used nil) (pairs nil))
    ;; By id first, so a renamed workspace is found under its old name.
    (dolist (d desired)
      (let ((a (and (plist-get d :id)
                    (cl-find (plist-get d :id) actual
                             :key (lambda (a) (plist-get a :id)) :test #'equal))))
        (when a (push a used))
        (push (cons d a) pairs)))
    (setq pairs (nreverse pairs))
    (dolist (pair pairs)
      (unless (cdr pair)
        (let ((a (cl-find-if (lambda (a) (and (not (memq a used))
                                              (equal (plist-get a :name)
                                                     (plist-get (car pair) :name))))
                             actual)))
          (when a (push a used) (setcdr pair a)))))
    (cons pairs (cl-remove-if (lambda (a) (memq a used)) actual))))

(defun terra-emacs-plan--moves (order want)
  "Moves taking the names ORDER to have WANT's names in WANT's order first."
  (let ((order (copy-sequence order)) (moves nil))
    (cl-loop for name in want for i from 0
             unless (equal (nth i order) name)
             do (setq order (remove name order))
             (setq order (append (cl-subseq order 0 (min i (length order)))
                                 (list name) (nthcdr (min i (length order)) order)))
             (push (list :op 'move :ws name :to i) moves))
    (nreverse moves)))

(defun terra-emacs-plan--layout-step (backend d a)
  "The layout step for desired D against actual A in BACKEND, or nil."
  (let ((want (plist-get d :layout)))
    (when want
      (if (null a)
          (list :op 'layout :ws (plist-get d :name) :layout want :why 'missing)
        (let ((have (terra-emacs-backend-with-workspace
                     backend (plist-get a :name) #'terra-emacs-layout-capture)))
          (cond ((not (terra-emacs-layout-same-p want have))
                 (list :op 'layout :ws (plist-get d :name) :layout want :why 'differs))
                ((terra-emacs-layout-stale-p have)
                 (list :op 'layout :ws (plist-get d :name) :layout want :why 'stale))))))))

(defun terra-emacs-plan (state &optional backend)
  "The steps that converge the live workspaces on STATE (or a state file).
BACKEND defaults to `terra-emacs-current-backend'.  Interactively, read
a state file and show the plan."
  (interactive (list (read-file-name "terra-emacs state: ")))
  (let* ((state (terra-emacs-plan--state state))
         (backend (or backend (terra-emacs-current-backend)))
         (desired (plist-get state :workspaces))
         (actual (terra-emacs-plan--actual backend))
         (matched (terra-emacs-plan--match desired actual))
         (pairs (car matched))
         (partial (plist-get state :partial))
         (kills (unless partial
                  (mapcar (lambda (a) (list :op 'kill :ws (plist-get a :name))) (cdr matched))))
         (renames nil) (creates nil) (ids nil) (levels nil) (params nil) (layouts nil)
         (current (terra-emacs-backend-current backend))
         (order (mapcar (lambda (a) (plist-get a :name)) actual))
         (steps nil))
    (when (and (plist-member state :levels)
               (not (equal (plist-get state :levels) (terra-emacs-backend-levels backend))))
      (push (list :op 'levels :levels (plist-get state :levels)) steps))
    (pcase-dolist (`(,d . ,a) pairs)
      (let ((name (plist-get d :name)))
        (cond ((null a)
               (push (list :op 'create :ws name :id (plist-get d :id)) creates)
               (setq order (append order (list name))))
              ((not (equal name (plist-get a :name)))
               (push (list :op 'rename :ws (plist-get a :name) :to name) renames)
               (when (equal current (plist-get a :name)) (setq current name))
               (setq order (cl-substitute name (plist-get a :name) order :test #'equal))))
        (when (and a (plist-get d :id) (not (equal (plist-get d :id) (plist-get a :id))))
          (push (list :op 'id :ws name :id (plist-get d :id)) ids))
        (unless (or (equal (plist-get d :level) (and a (plist-get a :level)))
                    (and partial (not (plist-member d :level))))
          (push (list :op 'level :ws name :level (plist-get d :level)) levels))
        (let ((have (and a (plist-get a :parameters))))
          (unless (cl-every (lambda (p) (equal (cdr p) (alist-get (car p) have)))
                            (plist-get d :parameters))
            (push (list :op 'parameters :ws name :parameters (plist-get d :parameters)) params)))
        (let ((step (terra-emacs-plan--layout-step backend d a)))
          (when step (push step layouts)))))
    (dolist (k kills)
      (setq order (remove (plist-get k :ws) order))
      (when (equal current (plist-get k :ws)) (setq current nil)))
    (setq steps
          (append (nreverse steps)
                  ;; Never empty the backend: with nothing kept, create first.
                  (if (cl-some #'cdr pairs) kills nil)
                  (nreverse renames) (nreverse creates)
                  (if (cl-some #'cdr pairs) nil kills)
                  (nreverse ids) (nreverse levels) (nreverse params)
                  (unless partial
                    (terra-emacs-plan--moves order (mapcar (lambda (d) (plist-get d :name)) desired)))
                  (nreverse layouts)))
    (let ((want (plist-get state :current)))
      (when (and want (not (equal want current)))
        (setq steps (append steps (list (list :op 'select :ws want))))))
    (when (called-interactively-p 'any) (terra-emacs-plan-show steps))
    steps))

;;;; Apply

(defun terra-emacs-plan--lay-out (backend name tree)
  "Lay TREE out in BACKEND's workspace NAME, adding the buffers it shows."
  (let ((terra-emacs-layout-show-functions
         (cons (lambda (_window buffer) (terra-emacs-backend-add-buffer backend name buffer))
               terra-emacs-layout-show-functions)))
    (terra-emacs-backend-with-workspace backend name
                                        (lambda () (terra-emacs-layout-apply tree)))))

(defun terra-emacs-plan--settle (backend want)
  "Move BACKEND's workspaces until WANT's names lead, in WANT's order.
tab-bar keeps a group's tabs together, so a level change can move one."
  (cl-loop repeat (* 2 (1+ (length want)))
           for order = (terra-emacs-backend-workspaces backend)
           for i = (cl-loop for name in want for j from 0
                            unless (equal (nth j order) name) return j)
           while i
           do (terra-emacs-backend-move backend (nth i want) i)))

(defun terra-emacs-plan--run (backend step)
  "Perform STEP in BACKEND."
  (let ((ws (plist-get step :ws)))
    (pcase (plist-get step :op)
      ('levels (terra-emacs-backend-set-levels backend (plist-get step :levels)))
      ('kill (terra-emacs-backend-kill backend ws))
      ('rename (terra-emacs-backend-rename backend ws (plist-get step :to)))
      ('create (terra-emacs-backend-create backend ws)
               (when (plist-get step :id)
                 (terra-emacs-backend-set-id backend ws (plist-get step :id))))
      ('id (terra-emacs-backend-set-id backend ws (plist-get step :id)))
      ('level (terra-emacs-backend-set-level backend ws (plist-get step :level)))
      ('parameters (pcase-dolist (`(,param . ,value) (plist-get step :parameters))
                     (terra-emacs-backend-set-parameter backend ws param value)))
      ('move (terra-emacs-backend-move backend ws (plist-get step :to)))
      ('layout (terra-emacs-plan--lay-out backend ws (plist-get step :layout)))
      ('select (terra-emacs-backend-select backend ws)))))

(defun terra-emacs-apply (state &optional dry-run backend)
  "Converge the live workspaces on STATE (a state or a state file).
With DRY-RUN (interactively, a prefix argument) change nothing.  Return
the plan; nil means nothing was (or would be) done.  BACKEND defaults
to `terra-emacs-current-backend'."
  (interactive (list (read-file-name "terra-emacs state: ") current-prefix-arg))
  (let* ((state (terra-emacs-plan--state state))
         (backend (or backend (terra-emacs-current-backend)))
         (plan (terra-emacs-plan state backend)))
    (unless dry-run
      (let ((tail (cl-remove-if (lambda (s) (memq (plist-get s :op) '(layout select))) plan)))
        (dolist (step tail) (terra-emacs-plan--run backend step))
        (when (and (not (plist-get state :partial))
                   (cl-some (lambda (s) (memq (plist-get s :op) '(level move create))) tail))
          (terra-emacs-plan--settle backend (mapcar (lambda (w) (plist-get w :name))
                                                    (plist-get state :workspaces))))
        (dolist (step plan)
          (when (memq (plist-get step :op) '(layout select))
            (terra-emacs-plan--run backend step)))))
    (when (called-interactively-p 'any) (terra-emacs-plan-show plan dry-run))
    plan))

;;;; Showing a plan

(defun terra-emacs-plan-describe (step)
  "STEP in words."
  (let ((ws (plist-get step :ws)))
    (pcase (plist-get step :op)
      ('levels (format "levels   %s" (mapconcat (lambda (l) (format "%s" (plist-get l :name)))
                                                (plist-get step :levels) ", ")))
      ('kill (format "kill     %s" ws))
      ('rename (format "rename   %s -> %s" ws (plist-get step :to)))
      ('create (format "create   %s" ws))
      ('id (format "id       %s := %s" ws (plist-get step :id)))
      ('level (format "level    %s -> %s" ws (or (plist-get step :level) "none")))
      ('parameters (format "params   %s %S" ws (plist-get step :parameters)))
      ('move (format "move     %s to position %d" ws (1+ (plist-get step :to))))
      ('layout (format "layout   %s (%s: %d window%s)" ws (plist-get step :why)
                       (length (terra-emacs-layout-leaves (plist-get step :layout)))
                       (if (= 1 (length (terra-emacs-layout-leaves (plist-get step :layout))))
                           "" "s")))
      ('select (format "select   %s" ws))
      (op (format "%s %s" op ws)))))

(defun terra-emacs-plan-show (plan &optional dry-run)
  "Show PLAN in the buffer *terra-emacs-plan*; DRY-RUN: say nothing ran."
  (with-current-buffer (get-buffer-create "*terra-emacs-plan*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (if plan
                  (format "terra-emacs plan: %d step%s%s\n\n" (length plan)
                          (if (= 1 (length plan)) "" "s") (if dry-run " (dry run)" ""))
                "terra-emacs plan: no changes\n"))
      (dolist (step plan) (insert "  " (terra-emacs-plan-describe step) "\n")))
    (special-mode)
    (goto-char (point-min))
    (display-buffer (current-buffer))))

(provide 'terra-emacs-plan)
;;; terra-emacs-plan.el ends here
