#lang racket/base
(provide current-buffer
         current-refresh-frame
         current-refresh-buffer
         current-default-major-mode
         current-append-next-kill
         ; gui
         current-render-points-only?
         current-show-points?
         current-point-color
         current-rendering-suspended?
         current-rendering-needed?
         ; 
         current-message
         ; completion
         current-completion-buffer
         current-completion-window
         ; rendering
         current-frame
         current-render-frame
         )

(require (for-syntax racket/base syntax/parse))

;;;
;;; PARAMETERS
;;;

(define current-buffer             (make-parameter #f))
(define current-refresh-frame      (make-parameter void)) 
(define current-refresh-buffer     (make-parameter void)) ; used in "buffer.rkt"

(define current-default-major-mode (make-parameter 'fundamental-mode))

(define current-append-next-kill   (make-parameter #f))


;;;
;;;GUI PARAMETERS
;;;

(define current-render-points-only?  (make-parameter #f))
(define current-show-points?         (make-parameter #f))
(define current-point-color          (make-parameter #f)) ; circular list of colors
(define current-rendering-suspended? (make-parameter #f))
(define current-rendering-needed?    (make-parameter #f))

(define current-message              (make-parameter #f))


;;;
;;; COMPLETIONS
;;;

(define current-completion-buffer    (make-parameter #f))
(define current-completion-window    (make-parameter #f))

;;;
;;; RENDERING
;;; 

(define current-frame                (make-parameter #f))

; This is a temporary fix to avoid circular module dependencies.
(define current-render-frame         (make-parameter #f))


