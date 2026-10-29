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
;; Reading and applying both go through Emacs's own window states:
;; each window's record rides in the `terra-emacs-leaf' window parameter
;; (listed in `window-persistent-parameters', as activities.el does),
;; reading takes the tree off `window-state-get' WRITABLE, and applying
;; turns the tree into a window state for `window-state-put' and then
;; shows each window's record.

;;; Code:

(require 'cl-lib)
(require 'terra-emacs-leaf)
(require 'terra-emacs-backend)

(add-to-list 'window-persistent-parameters '(terra-emacs-leaf . writable))

(defvar terra-emacs-layout-show-functions nil
  "Functions of a window and the buffer just shown in it by an apply.")

(defconst terra-emacs-layout-size-tolerance 0.05
  "How far two shares may differ and still count as the same layout.")

;;;; Reading a live layout

(defun terra-emacs-layout--share (x)
  "X rounded to two decimals."
  (/ (round (* 100 (or x 1.0))) 100.0))

(defun terra-emacs-layout--renormalize (sizes)
  "SIZES scaled to add up to one, each rounded to two decimals."
  (let ((sum (apply #'+ sizes)))
    (if (or (<= sum 0) (= (length sizes) 0))
        sizes
      (mapcar (lambda (s) (terra-emacs-layout--share (/ s sum))) sizes))))

(defun terra-emacs-layout--node (state leaf-fn)
  "The tree node of the window STATE (TYPE . ITEMS), or nil when it is empty.
LEAF-FN of a live buffer and the record stored with its window gives
the leaf's record.  A window whose buffer is gone keeps its stored
record; without one it is left out, as `window-state-put' leaves it
out (or shows another buffer in it) when the workspace is shown again."
  (let ((type (car state)) (items (cdr state)))
    (if (eq type 'leaf)
        (let* ((entry (cdr (assq 'buffer items)))
               (buffer (and entry (get-buffer (car entry))))
               (placed (alist-get 'terra-emacs-leaf (alist-get 'parameters items)))
               (rec (if (buffer-live-p buffer) (funcall leaf-fn buffer placed) placed)))
          (when rec
            (append (list :leaf rec)
                    (and (alist-get 'selected (cdr entry)) (list :selected t)))))
      (let* ((children (cl-remove-if-not (lambda (i) (memq (car-safe i) '(leaf vc hc))) items))
             (size (if (eq type 'hc) 'normal-width 'normal-height))
             (kept (delq nil (mapcar (lambda (c)
                                       (let ((node (terra-emacs-layout--node c leaf-fn)))
                                         (and node (cons (alist-get size (cdr c)) node))))
                                     children))))
        (cond ((null kept) nil)
              ((null (cdr kept)) (cdar kept))
              (t (list :split (if (eq type 'hc) 'right 'below)
                       :sizes (let ((sizes (mapcar (lambda (k) (terra-emacs-layout--share (car k)))
                                                   kept)))
                                (if (= (length kept) (length children))
                                    sizes
                                  (terra-emacs-layout--renormalize sizes)))
                       :children (mapcar #'cdr kept))))))))

(defun terra-emacs-layout--observe-leaf (buffer _placed)
  "BUFFER's observed record (`terra-emacs-leaf-observe')."
  (terra-emacs-leaf-observe buffer))

(defun terra-emacs-layout-read (state &optional leaf-fn)
  "The layout of the window STATE (from `window-state-get' WRITABLE).
LEAF-FN, of a live buffer and its window's stored record, gives each
leaf's record; default `terra-emacs-leaf-observe'."
  ;; A state may start with an alist of minimum sizes.
  (terra-emacs-layout--node (if (consp (car state)) (cdr state) state)
                            (or leaf-fn #'terra-emacs-layout--observe-leaf)))

(defun terra-emacs-layout--root (frame)
  "FRAME's main window: its root, less any side windows."
  (window-main-window frame))

(defun terra-emacs-layout--first (frame)
  "The first live window of FRAME's main window."
  (let ((root (terra-emacs-layout--root frame)))
    (if (window-live-p root)
        root
      (catch 'live
        (walk-window-subtree (lambda (w) (when (window-live-p w) (throw 'live w))) root)))))

(defun terra-emacs-layout-current (&optional frame leaf-fn)
  "The layout FRAME (default: the selected one) shows, side windows aside.
Each window's record (LEAF-FN, as for `terra-emacs-layout-read') is
stored in its `terra-emacs-leaf' parameter, so the workspace's saved
window state still names it after the buffer is gone."
  (let ((frame (or frame (selected-frame)))
        (leaf-fn (or leaf-fn #'terra-emacs-layout--observe-leaf)))
    (dolist (w (window-list frame 'nomini))
      (unless (window-parameter w 'window-side)
        (set-window-parameter w 'terra-emacs-leaf
                              (funcall leaf-fn (window-buffer w)
                                       (window-parameter w 'terra-emacs-leaf)))))
    (terra-emacs-layout-read (window-state-get (terra-emacs-layout--root frame) t)
                             (lambda (_buffer placed) placed))))

(defun terra-emacs-layout-of (backend name &optional leaf-fn)
  "The layout of BACKEND's workspace NAME.
LEAF-FN is as for `terra-emacs-layout-read'.  A hidden workspace is
read off the window state BACKEND keeps for it, so reading shows
nothing; else it is read shown."
  (let ((state (and (not (equal name (terra-emacs-backend-current backend)))
                    (terra-emacs-backend-window-state backend name))))
    (if state
        (terra-emacs-layout-read state leaf-fn)
      (terra-emacs-backend-with-workspace
       backend name (lambda () (terra-emacs-layout-current nil leaf-fn))))))

;;;; Apply

(defconst terra-emacs-layout--head
  (mapcar (lambda (k) (cons k 1))
          '(min-height min-width min-weight min-height-ignore min-width-ignore
            min-height-safe min-width-safe min-pixel-height min-pixel-width
            min-pixel-height-ignore min-pixel-width-ignore min-pixel-height-safe
            min-pixel-width-safe))
  "The minimum-sizes head of a synthesized window state.")

(defun terra-emacs-layout--buffer-entry (buffer selected)
  "The `buffer' item of a leaf showing BUFFER; SELECTED: its window is selected.
Every leaf needs one: `window-state-put' builds windows on a temporary
buffer and kills it after, which deletes any window still showing it."
  `(buffer ,(buffer-name buffer) (selected . ,selected) (hscroll . 0)
           (fringes nil nil nil nil) (margins nil) (scroll-bars nil nil nil nil nil nil nil)
           (vscroll . 0) (dedicated) (point . ,(with-current-buffer buffer (point)))
           (start . ,(with-current-buffer buffer (save-excursion (forward-line -2) (point))))))

(defun terra-emacs-layout--state-node (node width height last buffers)
  "The window state item of NODE, a WIDTH by HEIGHT share; LAST: the last child.
BUFFERS is a list cell whose car lists the leaves' buffers, consumed in order."
  (let ((common (append (and last (list '(last . t)))
                        (list (cons 'normal-width width) (cons 'normal-height height)))))
    (if (plist-member node :leaf)
        (let ((buffer (pop (car buffers))))
          `(leaf ,@common (parameters (terra-emacs-leaf . ,(plist-get node :leaf)))
                 ,(terra-emacs-layout--buffer-entry buffer (and (plist-get node :selected) t))))
      (let* ((right (eq (plist-get node :split) 'right))
             (children (plist-get node :children))
             (sizes (terra-emacs-layout--sizes node)))
        `(,(if right 'hc 'vc) ,@common
          ,@(cl-loop for (child . more) on children
                     for s in sizes
                     collect (terra-emacs-layout--state-node
                              child (if right s 1.0) (if right 1.0 s) (null more) buffers)))))))

(defun terra-emacs-layout--sizes (node)
  "NODE's shares, one per child, defaulting to equal ones."
  (let* ((n (length (plist-get node :children)))
         (sizes (plist-get node :sizes)))
    (if (= (length sizes) n) sizes (make-list n (/ 1.0 n)))))

(defun terra-emacs-layout-window-state (tree buffers)
  "The window state that `window-state-put' builds TREE from.
Its leaves show BUFFERS, in order."
  (let ((root (terra-emacs-layout--state-node tree 1.0 1.0 nil (list buffers))))
    ;; Zero totals and pixel sizes: never equal to the frame's, so the
    ;; normalized shares are used.
    (cons terra-emacs-layout--head
          (append (list (car root) '(pixel-width . 0) '(pixel-height . 0)
                        '(total-width . 0) '(total-height . 0))
                  (cdr root)))))

(defun terra-emacs-layout-apply (tree &optional frame)
  "Lay TREE out in FRAME (default: the selected one), showing each leaf."
  (let* ((frame (or frame (selected-frame)))
         (buffers (mapcar #'terra-emacs-leaf-restore (terra-emacs-layout-leaves tree))))
    (with-selected-frame frame
      (let ((first (terra-emacs-layout--first frame))
            (root (terra-emacs-layout--root frame)))
        (select-window first)
        ;; Only inside the main window: side windows stay.
        (unless (window-live-p root) (delete-other-windows-internal first root))
        (set-window-buffer first (car buffers)))
      (condition-case err
          (window-state-put (terra-emacs-layout-window-state tree buffers)
                            (terra-emacs-layout--root frame) 'safe)
        (error (message "terra-emacs: the frame cannot hold this layout (%s); one window"
                        (error-message-string err))
               (let ((first (terra-emacs-layout--first frame))
                     (root (terra-emacs-layout--root frame)))
                 (unless (window-live-p root) (delete-other-windows-internal first root))
                 (set-window-buffer first (car buffers))
                 (set-window-parameter first 'terra-emacs-leaf
                                       (car (terra-emacs-layout-leaves tree))))))
      (dolist (w (window-list frame 'nomini (terra-emacs-layout--first frame)))
        (unless (window-parameter w 'window-side)
          (run-hook-with-args 'terra-emacs-layout-show-functions w (window-buffer w)))))))

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
  "Non-nil when a leaf of the observed TREE lost its process."
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
