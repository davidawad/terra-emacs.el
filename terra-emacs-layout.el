;;; terra-emacs-layout.el --- window trees, declaratively -*- lexical-binding: t; -*-

;; Copyright (C) 2026 David Awad

;; Author: David Awad <davidawad@protonmail.com>
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A layout is a tree, in the spirit of kiwanami's window-layout recipes:
;;
;;   (:split right :sizes (0.5 0.5) :children (NODE NODE))  side by side
;;   (:split below :sizes (0.3 0.7) :children (NODE NODE))  stacked
;;   (:leaf RECORD [:selected t])                           a window
;;
;; SIZES are the children's shares of the split.  RECORD is a leaf
;; record (terra-emacs-leaf.el).
;;
;; Capture and apply both go through Emacs's own window states:
;; capturing stores each window's record in the `terra-emacs-leaf'
;; window parameter (listed in `window-persistent-parameters', as
;; activities.el does) and reads the tree off `window-state-get'
;; WRITABLE; applying turns the tree into a window state for
;; `window-state-put' and then shows each window's record.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-leaf)

(add-to-list 'window-persistent-parameters '(terra-emacs-leaf . writable))

(defvar terra-emacs-layout-show-functions nil
  "Functions of a window and the buffer just shown in it by an apply.")

(defconst terra-emacs-layout-size-tolerance 0.05
  "How far two shares may differ and still count as the same layout.")

;;;; Capture

(defun terra-emacs-layout--share (x)
  "X rounded to two decimals."
  (/ (round (* 100 (or x 1.0))) 100.0))

(defun terra-emacs-layout--node (state)
  "The tree node of the window STATE (TYPE . ITEMS)."
  (let ((type (car state)) (items (cdr state)))
    (if (eq type 'leaf)
        (let ((rec (alist-get 'terra-emacs-leaf (alist-get 'parameters items))))
          (append (list :leaf rec)
                  (and (alist-get 'selected (cdr (assq 'buffer items))) (list :selected t))))
      (let ((children (cl-remove-if-not (lambda (i) (memq (car-safe i) '(leaf vc hc))) items))
            (size (if (eq type 'hc) 'normal-width 'normal-height)))
        (list :split (if (eq type 'hc) 'right 'below)
              :sizes (mapcar (lambda (c) (terra-emacs-layout--share (alist-get size (cdr c))))
                             children)
              :children (mapcar #'terra-emacs-layout--node children))))))

(defun terra-emacs-layout-capture (&optional frame)
  "The layout of FRAME (default: the selected one)."
  (let ((frame (or frame (selected-frame))))
    (dolist (w (window-list frame 'nomini))
      (set-window-parameter w 'terra-emacs-leaf (terra-emacs-leaf-capture (window-buffer w))))
    (let ((state (window-state-get (frame-root-window frame) t)))
      ;; A writable state may start with an alist of minimum sizes.
      (terra-emacs-layout--node (if (consp (car state)) (cdr state) state)))))

;;;; Apply

(defconst terra-emacs-layout--head
  (mapcar (lambda (k) (cons k 1))
          '(min-height min-width min-weight min-height-ignore min-width-ignore
            min-height-safe min-width-safe min-pixel-height min-pixel-width
            min-pixel-height-ignore min-pixel-width-ignore min-pixel-height-safe
            min-pixel-width-safe))
  "The minimum-sizes head of a synthesized window state.")

(defun terra-emacs-layout--state-node (node width height last)
  "The window state item of NODE, a WIDTH by HEIGHT share; LAST: the last child."
  (let ((common (append (and last (list '(last . t)))
                        (list (cons 'normal-width width) (cons 'normal-height height)))))
    (if (plist-member node :leaf)
        `(leaf ,@common (parameters (terra-emacs-leaf . ,(plist-get node :leaf))))
      (let* ((right (eq (plist-get node :split) 'right))
             (children (plist-get node :children))
             (sizes (terra-emacs-layout--sizes node)))
        `(,(if right 'hc 'vc) ,@common
          ,@(cl-loop for (child . more) on children
                     for s in sizes
                     collect (terra-emacs-layout--state-node
                              child (if right s 1.0) (if right 1.0 s) (null more))))))))

(defun terra-emacs-layout--sizes (node)
  "NODE's shares, one per child, defaulting to equal ones."
  (let* ((n (length (plist-get node :children)))
         (sizes (plist-get node :sizes)))
    (if (= (length sizes) n) sizes (make-list n (/ 1.0 n)))))

(defun terra-emacs-layout-window-state (tree)
  "The window state `window-state-put' builds TREE from."
  (let ((root (terra-emacs-layout--state-node tree 1.0 1.0 nil)))
    ;; Zero totals and pixel sizes: never equal to the frame's, so the
    ;; normalized shares are used.
    (cons terra-emacs-layout--head
          (append (list (car root) '(pixel-width . 0) '(pixel-height . 0)
                        '(total-width . 0) '(total-height . 0))
                  (cdr root)))))

(defun terra-emacs-layout--selected (tree)
  "The 0-based index, in window order, of TREE's selected leaf, or nil."
  (let ((i -1) found)
    (cl-labels ((walk (node)
                  (if (plist-member node :leaf)
                      (progn (cl-incf i) (when (plist-get node :selected) (setq found i)))
                    (mapc #'walk (plist-get node :children)))))
      (walk tree))
    found))

(defun terra-emacs-layout-apply (tree &optional frame)
  "Lay TREE out in FRAME (default: the selected one), showing each leaf."
  (let* ((frame (or frame (selected-frame)))
         (root (frame-root-window frame)))
    (with-selected-frame frame
      (delete-other-windows (frame-first-window frame))
      (setq root (frame-root-window frame))
      (condition-case err
          (window-state-put (terra-emacs-layout-window-state tree) root 'safe)
        (error (message "terra-emacs: the frame cannot hold this layout (%s); one window"
                        (error-message-string err))
               (delete-other-windows (frame-first-window frame))
               (set-window-parameter (frame-first-window frame) 'terra-emacs-leaf
                                     (car (terra-emacs-layout-leaves tree)))))
      (let ((windows (window-list frame 'nomini (frame-first-window frame)))
            (selected (terra-emacs-layout--selected tree)))
        (dolist (w windows)
          (let ((rec (window-parameter w 'terra-emacs-leaf)))
            (when rec
              (let ((buf (terra-emacs-leaf-restore rec)))
                (set-window-buffer w buf)
                (set-window-point w (with-current-buffer buf (point)))
                (run-hook-with-args 'terra-emacs-layout-show-functions w buf)))))
        (when (and selected (nth selected windows))
          (select-window (nth selected windows)))))))

;;;; Comparing

(defun terra-emacs-layout-leaves (tree)
  "TREE's leaf records, in window order."
  (if (plist-member tree :leaf)
      (list (plist-get tree :leaf))
    (cl-mapcan #'terra-emacs-layout-leaves (plist-get tree :children))))

(defun terra-emacs-layout-same-p (a b)
  "Non-nil when layouts A and B show the same leaves in the same shape."
  (cond ((or (null a) (null b)) (eq a b))
        ((plist-member a :leaf)
         (and (plist-member b :leaf)
              (equal (terra-emacs-leaf-key (plist-get a :leaf))
                     (terra-emacs-leaf-key (plist-get b :leaf)))))
        (t (and (eq (plist-get a :split) (plist-get b :split))
                (= (length (plist-get a :children)) (length (plist-get b :children)))
                (cl-every (lambda (x y) (<= (abs (- x y)) terra-emacs-layout-size-tolerance))
                          (terra-emacs-layout--sizes a) (terra-emacs-layout--sizes b))
                (cl-every #'terra-emacs-layout-same-p
                          (plist-get a :children) (plist-get b :children))))))

(defun terra-emacs-layout-stale-p (tree)
  "Non-nil when a leaf of the captured TREE lost its process."
  (cl-some #'terra-emacs-leaf-stale-p (terra-emacs-layout-leaves tree)))

(defun terra-emacs-layout-clean (tree)
  "TREE without what never goes in a state file."
  (cond ((null tree) nil)
        ((plist-member tree :leaf)
         (let ((copy (copy-sequence tree)))
           (plist-put copy :leaf (terra-emacs-leaf-clean (plist-get tree :leaf)))))
        (t (let ((copy (copy-sequence tree)))
             (plist-put copy :children (mapcar #'terra-emacs-layout-clean
                                               (plist-get tree :children)))))))

(provide 'terra-emacs-layout)
;;; terra-emacs-layout.el ends here
