#lang racket/base
(provide status-line-hook)

;;;
;;; STATUS LINE
;;;

(require racket/format
         "buffer-locals.rkt"
         "mark.rkt"
         "mode.rkt"
         "parameters.rkt"
         "representation.rkt")


; The status line is shown at the bottom of a buffer window.
(define (status-line-hook)
  (define b (current-buffer))
  (cond
    [b (define save-status      (if (buffer-modified? b) "***" "---"))
       (define line?            (local   line-number-mode?))
       (define col?             (local column-number-mode?))
       (define-values (row col) (if (and (<= (buffer-length b) (local line-number-display-limit)))
                                    (mark-row+column (buffer-point b))
                                    (values "-" "-")))
       (define line+col         (cond [(and line? col?) (~a "(" row "," col ")")]
                                      [line?            (~a "L" row)]
                                      [col?             (~a "C" col)]
                                      [else             ""]))
       (~a save-status  
           "   " "Buffer: "          (buffer-name) "    " line+col
           "   " "Position: " (mark-position (buffer-point (current-buffer)))
           "   " "Length: "   (buffer-length (current-buffer))
           "   " "Mode: "     "(" (get-mode-name) ")")]
    [else
     "No current buffer"]))