#lang racket/base
(provide new-line
         
         line->string
         line-append
         line-blank?
         line-delete-backward-char!
         line-insert-char!
         line-insert-string!
         line-ref
         line-split
         
         string->line
         list->lines

         line-insert-embedded!
         line-embedded
         line-all-embedded
         line-embedded-from
         line-embedded-to
         line-embedded-between)

;;;
;;; LINE
;;;

(require racket/list racket/match racket/set
         "dlist.rkt"
         "representation.rkt"         
         "string-utils.rkt")

(module+ test (require rackunit))


; Defined in "representation.rkt"
; (struct line (strings length) #:transparent #:mutable)
;   A line is a list of elements of the types:
;     strings       represents actual text: list of strings, properties and overlays
;     property      represents a text property e.g. bold
;     overlay       represents ...


(define (add-ending-newline-if-needed s)
  (define n (string-length s))
  (cond
    [(= n 0)                                 "\n"]
    [(eqv? (string-ref s (- n 1)) #\newline) s]
    [else                                   (string-append s "\n")]))


; string->line : string -> line
(define (string->line s)
  (let ([s (add-ending-newline-if-needed s)])  
    (line (list s) (string-length s))))

; new-line : string ->list
;   anticipating extra options for new-line
(define (new-line s)
  (string->line s))


(module+ test (check-equal? (new-line "abc\n") (line '("abc\n") 4)))


; line->string : line -> string
;   return string contents of a line (i.e. remove properties and overlays)
(define (line->string l)
  (apply string-append (filter string? (line-strings l))))

(module+ test (check-equal? (line->string (new-line "abc\n")) "abc\n"))


; produces characters, properties and overlays - one at a time
(define (in-line l)
  (struct pos (rest i)) ; pos = comprehension position (not a text position)
  (define (pos->elm p)
    (match (first (pos-rest p))
      [(? string?   s) (string-ref s (pos-i p))]
      [(? embedded? e) e]
      [else (error 'pos->elm "internal error")]))
  (define (next-pos p)
    (define r (pos-rest p))
    (match (first r)
      [(? string? s) (define i (pos-i p))
                     (if (= (string-length s) (+ i 1))
                         (pos (rest r) 0)
                         (pos r (+ i 1)))]
      [(? embedded? e) (pos (rest r) 0)]
      [else (error 'next-post "internal error")]))
  (define initial-pos (pos (line-strings l) 0))
  (define (continue-with-pos? p) (not (empty? (pos-rest p))))
  (make-do-sequence
   (λ () (values pos->elm next-pos initial-pos continue-with-pos? #f #f))))

(define (line-blank? l)
  (string-whitespace? (line->string l)))

; list->lines : list-of-strings -> dlist-of-lines
(define (list->lines xs)
  (define (string->line s) (new-line s))
  (define (recur p xs)
    (cond 
      [(null? xs) dempty]
      [else       (define s (car xs))
                  (define l (new-line s))
                  (define d (linked-line l p #f #f (seteq)))
                  (define n (recur d (cdr xs)))
                  (set-dcons-n! d n)
                  d]))
  (cond 
    [(null? xs)   (dlist (new-line "\n") dempty dempty)]
    [else         (define s (car xs))
                  (define l (new-line s))
                  (define d (linked-line l dempty #f #f (seteq)))
                  (define n (recur d (cdr xs)))
                  (set-dcons-n! d n)
                  d]))

(module+ test (let ([xs '("ab\n" "cd\n")])
                (check-equal? (for/list ([x (list->lines xs)]) x)
                              (map new-line xs))))

; subline : line integer integer -> line
;   Return new line consisting of the characters, properties and overlays
;   between the indices i1 and i2.
;   If greedy any properties or overlays trailing the last string
;   also becomes part of the new line.
(define (subline l i1 i2 [greedy? #f])
  (define n (line-length l))
  (unless (<  i2 n)  (error 'subline "index ~a too large" i2))
  (unless (<= i1 i2) (subline l i2 i1))
  (define (skip-start i ss)
    ; ss = list of strings, property, overlay
    (if (= i 0) ss
        (match ss
          ['() '()]
          [(cons (? string? s) more)
           (define m (string-length s))
           (cond 
             [(< m i) (skip-start (- i m) more)]
             [else    (cons (substring s i m) more)])]
          [(cons _ more)
           (skip-start i more)])))
  (define (take-to i ss greedy?)
    (cond
      [(empty? ss) '()]
      [(= i 0)     (define head (first ss))
                   (if (and greedy?
                            (embedded? head))
                       (cons head (take-to i (rest ss) greedy?))
                       '())]
      [(< i 0)     '()]
      [else        (match ss
                     [(cons (? string? s) more)
                      (define n (string-length s))
                      (if (<= n i) 
                          (cons s (take-to (- i n) more greedy?))
                          (list (substring s 0 i)))]
                     [(cons (and head (? embedded s)) more)
                      (cons head (take-to i more greedy?))]
                     [_ (error 'take-to "expected list of strings, properties and overlays")])]))
  (take-to (- i2 i1) (skip-start i1 (line-strings l)) greedy?))


; line-ref : line index -> char
;   return the ith character of a line
(define (line-ref l i)
  (when (>= i (line-length l))
    (error 'line-ref "index ~a too large for line, got: ~a" i l))
  (let loop ([i i] [ss (line-strings l)])
    (match (first ss)
      [(? string? s) (define n (string-length s))
                     (if (< i n) 
                         (string-ref s i)
                         (loop (- i n) (rest ss)))]
      [_             (loop i (rest ss))])))



(define (string-insert-char s i c)
  (define n (string-length s))
  (unless (<= i n) (error 'string-insert-char "index too large, got ~a ~a" s i))
  (cond 
    [(= i n) (string-append s (string c))]
    [(= i 0) (string-append (string c) s)]
    [else    (string-append (substring s 0 i) (string c) (substring s i n))]))

(define (string-insert-string s i t) ; t is a string
  (define n (string-length s))
  (unless (<= i n) (error 'string-insert-string "index too large, got ~a ~a" s i))
  (cond 
    [(= i n) (string-append s t)]
    [(= i 0) (string-append t s)]
    [else    (string-append (substring s 0 i) t (substring s i n))]))

; skip-strings : list-of-strings-and-properties-and-overlays index -> index strings strings
;   If (j, us, vs) is returned,
;   then ss = (append us vs)
;   and  (string-ref (concat ss) i) = (string-ref (first vs) j).
;   If there are embedable values (properties or overlays) at index i,
;   they will be the first elements of vs.
(define (skip-strings ss i #:non-strings-as-after? [non-strings-returned-as-after? #f])
  (let loop ([i i] [before '()] [after ss])
    (cond 
      [(null? after) (values #f (reverse before) '())]
      [else          (define s (first after))
                     (cond
                       [(string? s) (define n (string-length s))
                                    (if (< i n)
                                        (values i (reverse before) after)
                                        (loop (- i n) (cons s before) (rest after)))]
                       ; non-string means property or overlay
                       [else        (if (and (= i 0) non-strings-returned-as-after?)
                                        (values i (reverse before) after)
                                        (loop i (cons s before) (rest after)))])])))

(module+ test
  (check-equal? (call-with-values (λ () (skip-strings '("ab" "cde" "fg") 0)) list)
                '(0 () ("ab" "cde" "fg")))
  (check-equal? (call-with-values (λ () (skip-strings '("ab" "cde" "fg") 1)) list)
                '(1 () ("ab" "cde" "fg")))
  (check-equal? (call-with-values (λ () (skip-strings '("ab" "cde" "fg") 2)) list)
                '(0 ("ab") ("cde" "fg"))))

; line-insert-char! : line char index -> void
;   insert char c in the line l at index i
(define (line-insert-char! l c i)
  (define n (line-length l))
  (unless (<= i n) (error 'line-insert-char! "index i greater than line length, i=~a, l=~a" i l))
  (define-values (j us vs) (skip-strings (line-strings l) i))
  (define v (first vs))
  (define vn (string-length v))
  (define w (cond 
              [(= j 0)  (string-append (string c) v)]
              [(= j vn) (string-append v (string c))]
              [else     (string-append (substring v 0 j) (string c) (substring v j vn))]))
  (set-line-strings! l (append us (cons w (rest vs))))
  (set-line-length!  l (+ n 1)))

; line-insert-string! : line string index -> void
;   insert string t in the line l at index i
(define (line-insert-string! l t i)
  (define n (line-length l))
  (unless (<= i n) (error 'line-insert-string! "index i greater than line length, i=~a, l=~a" i l))
  (define-values (j us vs) (skip-strings (line-strings l) i))
  (define v (first vs))
  (define vn (string-length v))
  (define w (cond 
              [(= j 0)  (string-append t v)]
              [(= j vn) (string-append v t)]
              [else     (string-append (substring v 0 j) t (substring v j vn))]))
  (set-line-strings! l (append us (cons w (rest vs))))
  (set-line-length!  l (+ n (string-length t))))


; line-insert-embedded! : line embedded index -> void
;   insert embedded value e in the line l at index i
(define (line-insert-embedded! l e i)
  (define n (line-length l))
  (unless (<= i n) (error 'line-insert-embedded! "index i greater than line length, i=~a, l=~a" i l))
  (define-values (j us vs) (skip-strings (line-strings l) i))
  (define v (first vs))
  (define vn (string-length v))
  (define w (cond 
              [(= j 0)  (cons e (list v))]
              [(= j vn) (append (list v) (list e))]
              [else     (list (substring v 0 j) e (substring v j vn))]))
  (set-line-strings! l (append us w (rest vs))))

; line-embedded : line index -> list
;    return a list of all embedded values at index i
(define (line-embedded l i)
  (define n (line-length l))
  (unless (<= i n)
    (error 'line-embedded "index i greater than line length, i=~a, l=~a" i l))
  (define-values (j us vs) (skip-strings (line-strings l) i #:non-strings-as-after? #t))
  (takef vs embedded?))

(define (line-properties l i) (filter property? (line-embedded l i)))
;(define (line-overlays   l i) (filter overlay?  (line-embedded l i)))

(define (line-all-embedded l)
  (filter embedded? (line-strings l)))

(define (line-embedded-from l i)
  (define n (line-length l))
  (unless (<= i n) (error 'line-all-embedded-from "index i greater than line length, i=~a, l=~a" i l))
  (define-values (j us vs) (skip-strings (line-strings l) i #:non-strings-as-after? #t))
  (filter embedded? vs))

(define (line-embedded-to l i)
  (define n (line-length l))
  (unless (<= i n) (error 'line-all-embedded-from "index i greater than line length, i=~a, l=~a" i l))
  (define-values (j us vs) (skip-strings (line-strings l) (+ i 1) #:non-strings-as-after? #t))
  (filter embedded? us))

(define (line-embedded-between l i k)
  (define n (line-length l))
  (unless (<= i n) (error 'line-all-embedded-from "index i greater than line length, i=~a, l=~a" i l))
  (unless (<= k n) (error 'line-all-embedded-from "index i greater than line length, i=~a, l=~a" k l))
  (define-values (j1 us vs) (skip-strings (line-strings l) i #:non-strings-as-after? #t))
  (define-values (j2 ss ts) (skip-strings vs (+ j1 (- k i)) #:non-strings-as-after? #t))
  (displayln (list 'j1 j1 'us us 'vs vs))
  (displayln (list 'j2 j2 'ss ss 'ts ts))
  (filter embedded? ss))

; line-split : line index -> line line
;   Split the line in two at the index.
(define (line-split l i)
  (define n (line-length l))
  (unless (<= i n) (error 'line-split "index ~a larger than line length ~a, the line is ~a" i n l))
  (define-values (j us vs) (skip-strings (line-strings l) i))  
  (cond
    [(empty? vs) (values l (line '("\n") 0))]
    [(= j 0)     (values (line (append us (list "\n")) (+ i 1))
                         (line vs (- n i)))]
    [else        (define s (first vs))
                 (define sn (string-length s))
                 (define s1 (substring s 0 j))
                 (define s2 (substring s j sn))
                 (values (line (append us (list (string-append s1 "\n"))) (+ i 1))
                         (line (cons s2 (rest vs)) (- n i)))]))

; line-append : line line -> line
;   append two lines, note the line ending of l1 is removed
(define (line-append l1 l2)
  (define ws (let loop ([us (line-strings l1)])
               ; we must remove the newline of the last string of us
               (if (null? (rest us))
                   (let ([s (substring (first us) 0 (- (string-length (first us)) 1))])
                     (if (equal? "" s)
                         (line-strings l2)
                         (cons s (line-strings l2))))
                   (cons (first us)
                         (loop (rest us))))))
  (line ws (+ (line-length l1) -1 (line-length l2))))

(module+ test
  (check-equal? (line-append (line '("a" "b\n") 3) (line '("c" "d\n") 3))
                (line '("a" "b" "c" "d\n") 5)))

; line-delete-backward-char! : line -> line
(define (line-delete-backward-char! l i)
  (unless (> i 0) (error 'line-delete-backward-char! "got ~a" i))
  (define-values (j us vs) (skip-strings (line-strings l) (- i 1)))
  ; (write (list 'back-char l i 'j j 'us us 'vs vs)) (newline)
  ;(when (null? vs) (error 'line-delete-backward-char! "expected non-empty line"))
  (unless (null? vs)
    (define s    (first vs))
    (define n    (string-length s))
    (define s1   (substring s 0 j)) 
    (define s2   (substring s (+ j 1) n))
    (define s1s2 (string-append s1 s2))
    (define ws   (if (equal? "" s1s2)
                     (append us (rest vs))
                     (append us (cons s1s2 (rest vs)))))
    (set-line-strings! l ws)
    (set-line-length! l (- (line-length l) 1))))

(module+ test
  (define del-char line-delete-backward-char!)
  (check-equal? (let ([l (line '("abc\n") 4)])     (del-char l 1) l) (line '("bc\n") 3))
  (check-equal? (let ([l (line '("abc\n") 4)])     (del-char l 2) l) (line '("ac\n") 3))
  (check-equal? (let ([l (line '("abc\n") 4)])     (del-char l 3) l) (line '("ab\n") 3))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 1) l) (line '("b" "cd\n") 4))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 2) l) (line '("a" "cd\n") 4))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 3) l) (line '("ab" "d\n") 4))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 4) l) (line '("ab" "c\n") 4)))
