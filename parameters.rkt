#lang racket/base
(provide current-prefix-argument
         current-buffer
         current-refresh-frame
         current-refresh-buffer
         current-append-next-kill
         ; gui
         current-render-points-only?
         ; current-show-points?
         current-point-color
         current-rendering-suspended?
         current-rendering-needed?
         ; 
         current-message
         current-global-keymap
         ; completion
         current-completion-buffer
         current-completion-window
         ; rendering
         current-frame
         current-window
         current-render-frame
         current-render-window
         ;
         current-next-screen-context-lines
         ;;; Globals
         cached-screen-lines-ht
         current-auto-mode-ht
         current-recently-opened-files
         current-update-recent-files-menu
         current-update-buffers-menu)

(require (for-syntax racket/base syntax/parse)
         "locals.rkt")

;;;
;;; GLOBALS
;;;

(define current-prefix-argument    (make-local #f)) ; set by C-u

(define current-buffer             (make-local #f))
(define current-refresh-frame      (make-local void)) 
(define current-refresh-buffer     (make-local void)) ; used in "buffer.rkt"

(define current-append-next-kill   (make-local #f))

;;;
;;; FILE AND I/O
;;;

; current-auto-mode-ht : hashtable from string to mode function
;   see mode.rkt
(define current-auto-mode-ht          (make-local (make-hash)))
(define current-recently-opened-files (make-local '()))
;;;
;;;GUI locals
;;;

(define current-render-points-only?  (make-parameter #f))
; (define current-show-points?         (make-local #f))
(define current-point-color          (make-local #f)) ; circular list of colors
(define current-rendering-suspended? (make-parameter #f))
(define current-rendering-needed?    (make-local #f))

(define current-message              (make-local #f))
(define current-global-keymap        (make-local #f))

(define current-update-recent-files-menu (make-local void))
(define current-update-buffers-menu      (make-local void))

;;;
;;; COMPLETIONS
;;;

(define current-completion-buffer    (make-local #f))
(define current-completion-window    (make-local #f))

;;;
;;; RENDERING
;;; 

(define current-frame                (make-local #f))
(define current-window               (make-local #f))

; This is a temporary fix to avoid circular module dependencies.
(define current-render-frame         (make-local void))
(define current-render-window        (make-local #f))

(define current-next-screen-context-lines (make-local 2)) ; TODO use a buffer local?

;;;
;;;
;;;


(define cached-screen-lines-ht (make-hasheq)) ; buffer -> info
