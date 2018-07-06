#lang racket/base
(provide overlays-positions
         overlays-ref
         overlays-ref/bounds
         overlays-set!
         overlays-contract-all
         overlays-stretch-all)
         
;;;
;;; OVERLAYS
;;;

; Overlays are not part of the text.
; Overlays belong to a buffer.
; The distinction is important, for example when the same text is displayed in two different buffers.

; Representation:
;   An overlay holds an hash table from symbols (names) to interval maps.
;   


(require ; data/interval-map
         "thread-safe-interval-maps.rkt"
         racket/dict racket/list racket/match
         "representation.rkt")

; overlays-set! : overlay integer integer symbol value -> void
(define (overlays-set! o from to sym val)
  (define ht (overlays-ht o))
  (define im (hash-ref ht sym #f))
  (unless im
    (set! im (make-safe-interval-map))
    (hash-set! ht sym im))
  (define before (safe-interval-map-ref im (- from 1) #f))
  (define after  (safe-interval-map-ref im   to       #f))
  (cond
    [(not im)
     ; if the symbol sym has not corresponding interval-map yet,
     ; we create one - and set the value
     (set! im (make-safe-interval-map))
     (hash-set! ht sym im)
     (safe-interval-map-set! im from to val)]
    [(and before after (equal? before val) (equal? after val))
     ; the value before and after the interval are associated to the same value,
     ; so we can coalesce the intervals.
     (define-values (from1 _ __)   (safe-interval-map-ref/bounds im (- from 1)))
     (define-values (___ to2 ____) (safe-interval-map-ref/bounds im to))
     (safe-interval-map-set! im from1 to2 val)]
    [(and before (equal? before val))
     ; coalesce with previous interval
     (define-values (from1 _ __) (safe-interval-map-ref/bounds im (- from 1)))
     (safe-interval-map-set! im from1 to val)]
    [(and after (equal? after val))
     ; coalesce with next interval
     (define-values (_ to1 __) (safe-interval-map-ref/bounds im to))
     (safe-interval-map-set! im from to1 val)]
    [else
     ; no coalescing needed
     (safe-interval-map-set! im from to val)]))

; overlays-ref : overlay symbol integer -> value
;   If no value is associated with the integer i, then the default argument is used.
;   If the default is a procedure, it is called. If not, the default value is returned.
(define (overlays-ref o sym i [default (λ () (error 'overlays-ref "no mapping found"))])
  (define ht (overlays-ht o))
  (define im (hash-ref ht sym #f))
  (safe-interval-map-ref im i default))


(define (overlays-ref/bounds o sym i [default #f])
  (define ht (overlays-ht o))
  (define im (hash-ref ht sym #f))
  (cond [im                   (safe-interval-map-ref/bounds im i default)]
        [(procedure? default) (default)]
        [else                 default]))

(define (overlays-stretch-all o i n)
  (define unique (gensym))
  (define ht (overlays-ht o))  
  (for ([sym (in-hash-keys (overlays-ht o))])
    (define im (hash-ref ht sym #f))
    (when im
      (define val (safe-interval-map-ref im (max 0 (- i 1)) unique))
      (safe-interval-map-expand! im i (+ i n))
      (unless (eq? val unique)
        (overlays-set! o i (+ i n) sym val)))))

(define (overlays-contract-all o i n)
  (define unique (gensym))
  (define ht (overlays-ht o))  
  (for ([sym (in-hash-keys (overlays-ht o))])
    (define im (hash-ref ht sym #f))
    (when im
      (safe-interval-map-contract! im i (+ i n)))))

(define (overlays-positions o sym)
  (define ht (overlays-ht o))
  (define im (hash-ref ht sym #f))  
  (cond [im (safe-interval-map-positions im)]
        [else '()]))

