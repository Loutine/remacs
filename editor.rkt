#lang racket
;;; TODO Let cursor blink back and forth from dark to light colors. 
;;;      That will work regardless of color scheme chosen by user.
;;; TODO Properties and faces
;;; TODO Modes
;;; TODO previous-buffer (parallel to next-buffer)
;;; TODO Introduce global that controls which key to use for meta
;;; TODO Finish eval-buffer
;;; TODO Implement open-input-buffer
;;; TODO Allow negative numeric prefix
;;; TODO Holding M and typing a number should create a numeric prefix.
;;; TODO Completions ala http://sublimetext.info/docs/en/extensibility/completions.html

(module+ test (require rackunit))
(require "dlist.rkt" (for-syntax syntax/parse) framework)
(require racket/gui/base)

;;;
;;; REPRESENTATION
;;;

(struct line (strings length) #:transparent #:mutable)
; A line is a list of elements of the types:
;   string        represents actual text
;   property      represents a text property e.g. bold
;   overlay       represents ...

; properties are copied as part of the text
; overlays are not copied - they are specifically not part of the text
(struct overlay  (specification) #:transparent)
(struct property (specification) #:transparent)

(struct linked-line dcons (version marks) #:transparent #:mutable)
; the element of a linked-line is a line struct
; marks is a set of marks located on the line
; version will be used for the redisplay code

(struct text (lines length) #:transparent #:mutable)
; A text being edited is represented as a doubly linked list of lines.

(struct stats (num-lines num-chars) #:transparent)
; The number of lines and number of characters in a text.

#;(struct buffer (text name path points marks modes cur-line num-chars num-lines modified? locals))
(module buffer-struct racket/base
  ; buffer-name and buffer-modified? are extendeded to handle current-buffer later on
  (provide (except-out (struct-out buffer) buffer-name buffer-modified?) 
           (rename-out [buffer-name -buffer-name] [buffer-modified? -buffer-modified?]))
  (struct buffer (text name path points marks modes cur-line num-chars num-lines modified? locals)
    #:transparent #:mutable))
(require (submod "." buffer-struct))
; A buffer is the basic unit of text being edited.
; It contains a text being edited.
; The buffer has a name, so the user can refer to the buffer.
; The buffer might have an associated file:
;   path = #f     <=>  buffer is not associated with a file
;   path = path   <=>  reads and writes to the file given by the path
; A point is a position between two characters. 
; Insertions and deletion will happen at the points (usually only one).
; If modified? is true, then the buffer has been modied since the last
; read or save of the file.
; The list modes contains the active modes (see below).
; A buffer can have multiple marks:

(struct mark (buffer link position name fixed?) #:transparent #:mutable)
; A mark rembers a position in the text of a buffer.
; The mark stores the link (linked-line) which hold the line.
; The mark name can be used to refer to the mark.
; fixed? = #f  A normal mark moves when insertions are made to the buffer.
; fixed? = #t  A fixed-mark remain in place.

; If there is exactly one mark, the area between the point and the mark
; is called a region.

(struct mode (name) #:transparent)
; A mode has a name (displayed in the status bar).

(struct window (frame panel borders canvas parent buffer) #:mutable #:transparent)
; A window is an area in which a buffer is displayed.
; Multiple windows are grouped in a frame.
; The contents of the buffer is rendered to the canvas.
; The canvas is contained in a panel.
; borders is a set of symbols indicating which borders to draw
;   'left 'right 'top 'bottom

(struct frame (frame% panel windows mini-window) #:mutable #:transparent)
; A frame contains one or multiple windows.
; About to change: The frame is render onto its canvas.

(struct            split-window       window ()            #:mutable #:transparent)
(struct horizontal-split-window split-window (left  right) #:mutable #:transparent)
(struct   vertical-split-window split-window (above below) #:mutable #:transparent)

; The buffer of a split window is #f.

;;;
;;; LINES
;;;

; string->line : string -> line
(define (string->line s)
  (line (list s) (string-length s)))

; new-line : string ->list
;   antipating extra options for new-line
(define (new-line s)
  (string->line s))

(module+ test (check-equal? (new-line "abc\n") (line '("abc\n") 4)))

; line->string : line -> string
;   return string contents of a line (i.e. remove properties and overlays)
(define (line->string l)
  (apply string-append (filter string? (line-strings l))))

(module+ test (check-equal? (line->string (new-line "abc\n")) "abc\n"))

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


; line-ref : line index -> char
;   return the ith character of a line
(define (line-ref l i)
  (when (>= i (line-length l))
    (error 'line-ref "index ~a to large for line, got: ~a" i l))
  (let loop ([i i] [ss (line-strings l)])
    (define s (first ss))
    (define n (string-length s))
    (if (< i n) 
        (string-ref s i)
        (loop (- i n) (rest ss)))))

(module+ test
  (define illead-text 
    (new-text 
     (list->lines
      (list "x\n"))))
  #;(define illead-text 
      (new-text 
       (list->lines
        (list "Sing, O goddess, the anger of Achilles son of Peleus, that brought\n"
              "countless ills upon the Achaeans. Many a brave soul did it send hurrying\n"
              "down to Hades, and many a hero did it yield a prey to dogs and vultures,\n"
              "for so were the counsels of Jove fulfilled from the day on which the\n"
              "son of Atreus, king of men, and great Achilles, first fell out with\n"
              "one another.\n"))))
  
  
  ; recreate the same text file from scratch
  (define (create-new-test-file path)
    (with-output-to-file path
      (λ() (for ([line (text-lines illead-text)])
             (for ([s (line-strings line)])
               (display s))))
      #:exists 'replace)))

(define (string-insert-char s i c)
  (define n (string-length s))
  (unless (<= i n) (error 'string-insert-char "index too large, got ~a ~a" s i))
  (cond 
    [(= i n) (string-append s (string s))]
    [(= i 0) (string-append (string c) s)]
    [else    (string-append (substring s 0 i) (string c) (substring s i n))]))

; skip-strings : list-of-strings index -> index strings strings
;   If (j, us, vs) is returned,
;   then ss = (append us vs)
;   and  (string-ref (concat ss) i) = (string-ref (first vs) j)
(define (skip-strings ss i)
  (let loop ([i i] [before '()] [after ss])
    (cond 
      [(null? after) (values #f (reverse before) '())]
      [else          (define s (first after))
                     (cond
                       [(string? s) (define n (string-length s))
                                    (if (< i n)
                                        (values i (reverse before) after)
                                        (loop (- i n) (cons s before) (rest after)))]
                       [else         (loop i (cons s before) (rest after))])])))

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


; line-insert-property! : line property index -> void
;   insert property p in the line l at index i
(define (line-insert-property! l p i)
  (define n (line-length l))
  (unless (<= i n) (error 'line-insert-property! "index i greater than line length, i=~a, l=~a" i l))
  (define-values (j us vs) (skip-strings (line-strings l) i))
  (define v (first vs))
  (define vn (string-length v))
  (define w (cond 
              [(= j 0)  (cons p (list v))]
              [(= j vn) (append (list v) (list p))]
              [else     (list (substring v 0 j) p (substring v j vn))]))
  (set-line-strings! l (append us w (rest vs)))
  (set-line-length!  l (+ n 1)))

; line-split : line index -> line line
;   split the line in two at the index
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
  (define s    (first vs))
  (define n    (string-length s))
  (define s1   (substring s 0 j)) 
  (define s2   (substring s (+ j 1) n))
  (define s1s2 (string-append s1 s2))
  (define ws   (if (equal? "" s1s2)
                   (append us (rest vs))
                   (append us (cons s1s2 (rest vs)))))
  (set-line-strings! l ws)
  (set-line-length! l (- (line-length l) 1)))

(module+ test
  (define del-char line-delete-backward-char!)
  (check-equal? (let ([l (line '("abc\n") 4)])     (del-char l 1) l) (line '("bc\n") 3))
  (check-equal? (let ([l (line '("abc\n") 4)])     (del-char l 2) l) (line '("ac\n") 3))
  (check-equal? (let ([l (line '("abc\n") 4)])     (del-char l 3) l) (line '("ab\n") 3))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 1) l) (line '("b" "cd\n") 4))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 2) l) (line '("a" "cd\n") 4))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 3) l) (line '("ab" "d\n") 4))
  (check-equal? (let ([l (line '("ab" "cd\n") 5)]) (del-char l 4) l) (line '("ab" "c\n") 4)))

;;;
;;; TEXT
;;;

; new-text : -> text
;   create an empty text
(define (new-text [lines dempty])
  (cond 
    [(dempty? lines) (text (linked-line (new-line "\n") dempty dempty "no-version-yet" '()) 1)]
    ; linked correctly?  
    ; xxx
    [else            (text lines (for/sum ([l lines])
                                   (line-length l)))]))

; text-line : text integer -> line
;   the the ith line
(define (text-line t i)
  (dlist-ref (text-lines t) i))  

; text-append! : text text -> text
(define (text-append! t1 t2)
  (text (dappend! (text-lines t1) (text-lines t2))
        (+ (text-length t1) (text-length t2))))

; text->string : text -> string
;   convert the text to a string
(define (text->string t)
  (apply string-append
    (for/list ([l (text-lines t)])
      (line->string l))))

; path->text : path -> text
;   create a text with contents from the file given by path
(define (path->text path)
  (define (DCons a p n) (linked-line a p n #f (seteq)))
  (with-input-from-file path 
    (λ () (new-text (for/dlist #:dcons DCons ([s (in-lines)])
                      (string->line (string-append s "\n")))))))

(module+ test
  (void (create-new-test-file "illead.txt"))
  ; (displayln "--- illead test file ---")
  ; (write (path->text "illead.txt")) (newline)
  ; (displayln "---")
  ;(write illead-text) (newline)
  ;(displayln "---")
  #;(check-equal? (path->text "illead.txt") illead-text))

; text-num-lines : text -> natural
;   return number of lines in the text
(define (text-num-lines t)
  (dlength (text-lines t)))

(define (text-num-chars t)
  (for/sum ([line (text-lines t)])
    (line-length line)))

(define (text-stats t)
  (define-values (nlines nchars)
    (for/fold ([nl 0] [nc 0]) ([l (text-lines t)])
      (values (+ nl 1) (+ nc (line-length l)))))
  (stats nlines nchars))

(define (text-insert-char-at-mark! t m b c)
  (define-values (row col) (mark-row+column m))
  (define l (dlist-ref (text-lines t) row))
  (line-insert-char! l c col)
  (set-text-length! t (+ (text-length t) 1)))

; text-break-line! : text natural natural -> void
;   break line number row into two at index col
(define (text-break-line! t row col)
  (define d (dlist-move (text-lines t) row))
  (define l (dfirst d))
  (define-values (pre post) (line-split l col)) ; xxx
  (set-dcons-a! d pre)
  (dinsert-after! d post (λ (a p n) (linked-line a p n #f (seteq))))
  (set-text-length! t (+ 1 (text-length t))))

; text-delete-backward-char! : text natural natural -> void
;   delete the char at line row before column col
(define (text-delete-backward-char! t row col)
  (define d (dlist-move (text-lines t) row))
  (define l (dfirst d))
  (define n (text-length t))
  (cond
    [(> col 0) (line-delete-backward-char! l col)
               (set-text-length! t (- n 1))]
    [(and (= col 0) (= row 0))
     (beep "Beginning of buffer")]
    [(= col 0) 
     ; we need to append this line to the previous
     (define p (dcons-p d))
     (define pl (dfirst p))
     (set-dcons-a! p (line-append pl l))
     (dcons-remove! d)
     (set-text-length! t (- n 1))]
    [else      ; 
     (error 'todo)]))

(define beep void)

;;;
;;; MARKS
;;;

(define (mark-compare m1 m2 cmp)
  (define (pos m) (if (mark? m) (mark-position m) m))
  (cmp (pos m1) (pos m2)))
(define (mark<  m1 m2) (mark-compare m1 m2 <))
(define (mark=  m1 m2) (mark-compare m1 m2 =))
(define (mark>  m1 m2) (mark-compare m1 m2 >))
(define (mark<= m1 m2) (mark-compare m1 m2 <=))
(define (mark>= m1 m2) (mark-compare m1 m2 >=))

; new-mark : buffer string integer boolean -> mark
(define (new-mark b name [pos 0] [fixed? #f])
  ; (define link (text-lines (buffer-text b)))
  (define link (text-lines (buffer-text b)))
  (define m (mark b link pos name fixed?))
  (displayln (list 'new-mark link)) ; xxx
  (set-linked-line-marks! link (set-add (linked-line-marks link) m))
  m)

; delete-mark! : mark -> void
;   remove the mark from the line it belongs to
(define (delete-mark! m)
  ; remove mark from line
  (define link (mark-link m))
  (define b (mark-buffer m))
  (set-linked-line-marks! link (set-remove (linked-line-marks link) m))
  ; remove mark from buffer
  (set-buffer-marks! b (filter (λ(x) (not (eq? x m))) (buffer-marks b))))

; mark-move! : mark integer -> void
;  move the mark n characters
(define (mark-move! m n)
  (define b  (mark-buffer m))
  (define p  (mark-position m))
  (define l  (dfirst (mark-link m)))
  (define ln (line-length l))
  (define-values (old-r old-c) (mark-row+column m))
  ; new position
  (define q (if (> n 0)
                (min (+ p n) (max 0 (- (buffer-length b) 1)))
                (max (+ p n) 0)))
  (set-mark-position! m q)
  (define-values (r c) (mark-row+column m))
  (unless (= old-r r)
    ; remove mark from old line
    (define link (mark-link m))
    (set-linked-line-marks! link (set-remove (linked-line-marks link) m))
    ; insert mark in new line
    (define new-link (dlist-move (first-dcons link) r))
    ; (displayln new-link)
    (set-linked-line-marks! new-link (set-add (linked-line-marks new-link) m))
    ; the mark must point to the new line
    (set-mark-link! m new-link)))

; mark-adjust-insertion-after! : mark integer natural -> void
;   adjust the position of the mark - an amount of a characters were inserted at position p
(define (mark-adjust-insertion-after! m p a)
  (define mp (mark-position m))
  (when (> mp p)
    ; the insertion was before the mark
    (mark-move! m a)))

; mark-adjust-insertion-before! : mark integer natural -> void
;   adjust the position of the mark - an amount of a characters were inserted at position p
(define (mark-adjust-insertion-before! m p a)
  (define mp (mark-position m))
  (when (>= mp p)
    ; the insertion was before the mark
    (mark-move! m a)))

; mark-adjust-deletion-before! : mark integer natural -> void
;   adjust the position of the mark - an amount of a characters were deleted before position p
(define (mark-adjust-deletion-before! m p a)
  (define mp (mark-position m))
  (cond 
    ; the entire deletion was before the mark
    [(<= p mp)      (mark-move! m (- a))]
    ; the entire deletion was after the mark
    [(< mp (- p a)) (void)]
    ; overlap
    [else           (mark-move! m (- a (- p mp)))]))

; mark-adjust-deletion-after! : mark integer natural -> void
;   adjust the position of the mark - an amount of a characters were after before position p
(define (mark-adjust-deletion-after! m p a)
  (define mp (mark-position m))
  (cond 
    ; the entire deletion was after the mark
    [(<= mp p)       (void)]
    ; the entire deletion was before the mark
    [(<= (+ p a) mp) (mark-move! m (- a))]
    ; overlap
    [else            (mark-move! m (- mp p))]))

; clamp : number number number -> number
;   if minimum <= x <= maximum, return x
;   if x < minimum, return minimum
;   if x > maximum, return maximum
(define (clamp minimum x maximum)
  (max minimum (min x maximum)))

; mark-move-to-column! : mark integer -> void
;   move mark to column n (stay at line)
(define (mark-move-to-column! m n)
  (define-values (r c) (mark-row+column m))
  (unless (= n c)
    (let ([n (clamp 0 n c)]) ; stay on same line
      (mark-move! m (- n c)))))

; mark-row+column : mark- > integer integer
;   return row and column number for the mark m
(define (mark-row+column m)
  (define b (mark-buffer m))
  (define p (mark-position m))
  (define-values (row col)
    (let/ec return
      (for/fold ([r 0] [q 0]) ([l (text-lines (buffer-text b))])
        ; q is the first position on line r
        (define n (line-length l))
        (if (> (+ q n) p)
            (return r (- p q))
            (values (+ r 1) (+ q n))))))
  (values row col))

; mark-move-beginning-of-line! : mark -> void
;   move the mark to the begining of its line
(define (mark-move-beginning-of-line! m)
  (define p (mark-position m))
  (define-values (row col) (mark-row+column m))
  (set-mark-position! m (- p col)))

; mark-move-end-of-line! : mark -> void
;   move the mark to the end of its line
(define (mark-move-end-of-line! m)
  (define b (mark-buffer m))
  (define p (mark-position m))
  (define-values (row col) (mark-row+column m))
  (define n (line-length (dlist-ref (text-lines (buffer-text b)) row)))
  (set-mark-position! m (+ p (- n col) -1)))

; mark-move-up! : mark -> void
;   move mark up one line
(define (mark-move-up! m)
  (define p (mark-position m))
  (define-values (row col) (mark-row+column m))
  (unless (= row 0)
    (define link (dlist-move (first-dcons (text-lines (buffer-text (mark-buffer m)))) (- row 1)))
    (define l (dfirst link)) ; line
    (define new-col (min (line-length l) col))
    (define new-pos (- p col (line-length l) (- new-col)))
    (set-mark-position! m new-pos)
    (set-linked-line-marks! link (set-add (linked-line-marks link) m))
    (define old-link (dlist-move link 1))
    (set-linked-line-marks! old-link (set-remove (linked-line-marks link) m))))

; mark-move-down! : mark -> void
;  move mark down one line
(define (mark-move-down! m)
  (define p (mark-position m))
  (define-values (row col) (mark-row+column m))
  (define t (buffer-text (mark-buffer m)))
  (unless (= (+ row 1) (text-num-lines t))
    (define d (dlist-move (text-lines t) row))
    (set-linked-line-marks! d (set-remove (linked-line-marks d) m))
    (define l1 (dfirst d))
    (define l2 (dlist-ref d 1))
    (define new-col (min (line-length l2) col))
    (define new-pos (+ p (- (line-length l1) col) new-col))
    (set-mark-position! m new-pos)
    (define d+ (dlist-move d 1))
    (set-linked-line-marks! d+ (set-add (linked-line-marks d+) m))))

; mark-backward-word! : mark -> void
;   move mark backward until a word separator is found
(define (mark-backward-word! m)
  (define-values (row col) (mark-row+column m))
  (define t (buffer-text (mark-buffer m)))
  (define l (text-line t row))
  ; first skip whitespace
  (define i (for/first ([i (in-range (- col 1) -1 -1)]
                        #:when (not (word-separator? (line-ref l i))))
              i))
  (cond
    [(or (not i) (= i 0))
     ; continue searching for word at previous line (unless at top line)
     (mark-move-beginning-of-line! m)
     (unless (= row 0)
       (mark-move! m -1)
       (mark-backward-word! m))]
    [else
     ; we have found a word, find the beginning
     (define j (for/first ([j (in-range (or i (- col 1)) -1 -1)]
                           #:when (word-separator? (line-ref l j)))
                 j))
     ; j is now the index of the first word separator
     (mark-move! m (- (if j (- col (+ j 1)) col)))]))

; mark-forward-word! : mark -> void
;   move mark forward until a word separator is found
(define (mark-forward-word! m)
  (define-values (row col) (mark-row+column m))
  (define t (buffer-text (mark-buffer m)))
  (define l (text-line t row))
  (define n (line-length l))
  ; first skip whitespace
  (define i (for/first ([i (in-range col n)]
                        #:when (not (word-separator? (line-ref l i))))
              i))
  (cond
    [(or (not i) (= i (- n 1)))
     ; continue searching for word at next line (unless at bottom line)
     (mark-move-end-of-line! m)
     (unless (= row (- (text-num-lines t) 1))
       (mark-move! m 1)
       (mark-forward-word! m))]
    [else
     ; we have found a word, find the beginning
     (define j (for/first ([j (in-range (or i (- col 1)) n)]
                           #:when (word-separator? (line-ref l j)))
                 j))
     ; j is now the index of the first word separator
     (mark-move! m (if j (- j col) col))]))

(define (mark-move-to-position! m n)
  (displayln (list 'mark-move-to-position m n))
  ; remove mark from its current line
  (define l (mark-link m))
  (set-linked-line-marks! l (set-remove (linked-line-marks l) m))
  ; find the new line
  (define-values (row col) (mark-row+column m))
  (define d (dlist-move (text-lines (buffer-text (mark-buffer m))) row))
  ; add mark to the new line
  (set-linked-line-marks! d (set-add (linked-line-marks d) m))
  ; store the new position
  (set-mark-position! m n))

;;;
;;; WORDS
;;;

(define (word-separator? c)
  (char-whitespace? c))

;;;
;;; BUFFER
;;;

; buffer-name : [buffer] -> string
;   return name of buffer
(define (buffer-name [b (current-buffer)]) 
  (-buffer-name b))

; all buffers are registered in buffers-ht
(define buffers-ht (make-hash))  ; string -> buffer
(define all-buffers '())

; register-buffer : buffer [thunk-or-#f] -> void
;   associate (buffer-name b) to b in buffers-ht,
;   and put it all-buffers
(define (register-buffer b [on-error #f])
  (define name (buffer-name b))
  (if (hash-ref buffers-ht name #f)
      (cond 
        [on-error (on-error)]
        [else (error 'register-buffer 
                     "attempt to register buffer with name already in use: ~a" name)])
      (hash-set! buffers-ht name b))
  (set! all-buffers (cons b all-buffers)))

; get-buffer : buffer-or-string -> buffer-or-#f
;   return buffer specified by buffer-or-name
(define (get-buffer buffer-or-name)
  (define b buffer-or-name)
  (if (buffer? b) b (hash-ref buffers-ht b #f)))

; generate-new-buffer-name : string -> string
;   generate buffer name not in use
(define (generate-new-buffer-name starting-name)
  (define (name i) (if (= i 1) starting-name (~a starting-name i)))
  (for/first ([i (in-naturals 1)]
              #:unless (get-buffer (name i)))
    (name i)))

; new-buffer : -> buffer
;   create fresh buffer without an associated file
(define (new-buffer [text (new-text)] [path #f] [name (generate-new-buffer-name "buffer")])
  (define b (buffer text name path 
                    '()   ; points
                    '()   ; marks
                    '()   ; modes 
                    0     ; cur-line
                    0     ; num-chars
                    0     ; num-lines
                    #f    ; modified?
                    (make-empty-namespace)))  ; locals
  (define point (new-mark b "*point*"))
  (define points (list point))
  (set-buffer-points! b points)
  (define stats (text-stats text))
  (define num-lines (stats-num-lines stats))
  (set-buffer-num-lines! b num-lines)
  (define num-chars (stats-num-chars stats))
  (set-buffer-num-chars! b num-chars)
  (register-buffer b)
  b)



; generate-new-buffer : string -> buffer
(define (generate-new-buffer name)
  (unless (string? name) (error 'generate-new-buffer "string expected, got ~a" name))
  (new-buffer (new-text) #f (generate-new-buffer-name name)))

(define scratch-buffer (new-buffer (new-text (list->lines '("The scratch buffer\n"))) #f "*scratch*"))
(define current-buffer (make-parameter scratch-buffer))

; syntax: (save-current-buffer body ...)
;   store current-buffer while evaluating body ...
;   the return value is the result from the last body
(define-syntax (save-current-buffer stx)
  (syntax-parse stx
    [(s-c-b body ...)
     #'(let ([b (current-buffer)])
         (begin0 (begin body ...)
                 (current-buffer b)))]))

; syntax (with-current-buffer buffer-or-name body ...)
;   use buffer-or-name while evaluating body ...,
;   restore current buffer afterwards
(define-syntax (with-current-buffer stx)
  (syntax-parse stx
    [(w-c-b buffer-or-name body ...)
     #'(parameterize ([current-buffer buffer-or-name])
         ; (todo "lookup buffer if it is a name")
         body ...)]))

; TODO syntax  (with-temp-buffer body ...)

; rename-buffer! : string -> string
(define (rename-buffer! new-name [b (current-buffer)] [unique? #t])
  (unless (string? new-name) (error 'rename-buffer "string expected, got " new-name))
  ; todo: check that buffer-name is not in use, if it is signal error unless unique? is false
  ;       in that case generate new name and return it
  (set-buffer-name! b new-name)
  new-name)

(define (buffer-modified? [b (current-buffer)])
  (-buffer-modified? b))

(define (buffer-dirty! [b (current-buffer)])
  (set-buffer-modified?! b #t))

; set-buffer-modified! : any [buffer] -> void
;   set modified?, redisplay mode line
(define (set-buffer-modified! flag [b (current-buffer)])
  ; TODO (redisplay-mode-line-for-current-buffer]
  (when flag (set-buffer-modified?! b #t)))

; get-buffer-create : buffer-or-name -> buffer
;   get buffer with given name, if none exists, create it
(define (get-buffer-create buffer-or-name)
  (define b buffer-or-name)
  (if (buffer? b) b (generate-new-buffer b)))

(define (buffer-open-file-or-create file-path)
  (define path (if (string? file-path) (string->path file-path) file-path))
  (unless (file-exists? path)
    (close-output-port (open-output-file path)))
  (define filename (last (map path->string (explode-path path))))
  (define text     (path->text path))
  (new-buffer text path (generate-new-buffer-name filename)))


; save-buffer : buffer -> void
;   save contents of buffer to associated file
;   do nothing if no file is associated
(define (save-buffer! b)
  (define file (buffer-path b))
  (unless file
    (set! file (finder:put-file)))
  (when file
    (with-output-to-file file
      (λ () (for ([line (text-lines (buffer-text b))])
              (for ([s (line-strings line)])
                (display s))))
      #:exists 'replace)
    (set-buffer-modified?! b #f)))

; save-buffer-as : buffer ->
;   get new file name from user, 
;   associate file with buffer,
;   and save it
(define (save-buffer-as! b)
  (define file (finder:put-file))
  (when file
    (set-buffer-path! b file)
    (save-buffer! b)))

(define (make-output-buffer b)
  ;; State
  (define count-lines? #f)
  ;; Setup port
  (define name (buffer-name b)) ; name for output port
  (define evt  always-evt)      ; writes never block
  (define write-out             ; handles writes to port
    (λ (out-bytes start end buffered? enable-breaks?)
      ; write bytes from out-bytes from index start (inclusive) to index end (exclusive)
      (define the-bytes (subbytes out-bytes start end))
      (define as-string (bytes->string/utf-8 the-bytes))
      (buffer-insert-string-before-point! b as-string)
      (buffer-dirty! b)
      (refresh-frame)   ; todo how to find the correct the frame?
      ; number of bytes written
      (- end start)))
  (define close                 ; closes port
    (λ () (void)))
  (define write-out-special     ; handles specials?
    #f)                         ; (not yet)
  (define get-write-evt         ; #f or procedure that returns synchronizable event
    #f)
  (define get-write-special-evt ; same for specials
    #f)
  (define get-location          ; #f or procedure that returns 
    (λ ()                       ; line number, column number, and position
      (when count-lines?
        (define m (buffer-point b))
        (define-values (row col) (mark-row+column m))
        (values (+ 1 row) col (+ 1 (mark-position m))))))
  (define count-lines!
    (λ () (set! count-lines? #t)))
  (define init-position (+ 1 (mark-position (buffer-point b)))) ; 
  (define buffer-mode #f)
  (make-output-port name evt write-out close write-out-special get-write-evt
                    get-write-special-evt get-location count-lines! init-position buffer-mode))

(module+ test
  (provide illead-buffer)
  (define illead-buffer (new-buffer illead-text "illead.txt" (generate-new-buffer-name "illead")))
  (save-buffer! illead-buffer)
  #;(check-equal? (path->text "illead.txt") illead-text))

; read-buffer : buffer -> void
;   replace text of buffer with file contents
(define (read-buffer! b)
  (define path (buffer-path b))
  (unless path (error 'read-buffer "no associated file: ~a" b))
  (define text (path->text path))
  (define stats (text-stats text))
  (set-buffer-text! b text)
  (set-buffer-num-lines! b (stats-num-lines stats))
  (set-buffer-num-chars! b (stats-num-chars stats))
  (set-buffer-modified?! b #f)
  (buffer-dirty! b))

(module+ test
  (void (create-new-test-file "illead.txt"))
  (define b (new-buffer (new-text) "illead.txt" (generate-new-buffer-name "illead")))
  (read-buffer! b)
  #;(check-equal? b illead-buffer))

; append-to-buffer-from-file : buffer path -> void
;   append contents of file given by the path p to the text of the buffer b
(define (append-to-buffer-from-file b p)
  (define text-to-append (path->text p))
  (define stats (text-stats text-to-append))
  (set-buffer-text! b (text-append! (buffer-text b) text-to-append))
  (set-buffer-num-lines! b (+ (buffer-num-lines b) (stats-num-lines stats)))
  (set-buffer-num-chars! b (+ (buffer-num-chars b) (stats-num-chars stats)))
  (set-buffer-modified?! b #t)
  (buffer-dirty! b))

(module+ test
  (void (create-new-test-file "illead.txt"))
  (define append-buffer (new-buffer (new-text)))
  (append-to-buffer-from-file append-buffer "illead.txt")
  (append-to-buffer-from-file append-buffer "illead.txt")
  (save-buffer! b) ; make sure the buffer is unmodified before comparison
  #;(check-equal? (buffer-text append-buffer) (text-append! illead-text illead-text)))

; buffer-point : buffer -> mark
;   return the first mark in the list of points
(define (buffer-point b)
  (first (buffer-points b)))

; buffer-point-set! : buffer mark -> void
;   set the point at the position given by the mark m

(define (point [b (current-buffer)])
  (buffer-point b))

(define (buffer-move-point! b n)
  (mark-move! (buffer-point b) n))

(define (buffer-move-point-up! b)
  (mark-move-up! (buffer-point b)))

(define (buffer-move-point-down! b)
  (mark-move-down! (buffer-point b)))

(define (buffer-move-to-column! b n)
  (mark-move-to-column! (buffer-point b) n))

; buffer-backward-word! : buffer -> void
;   move point forward until a word separator is found
(define (buffer-backward-word! b)
  (mark-backward-word! (buffer-point b)))

; buffer-forward-word! : buffer -> void
;   move point to until it a delimiter is found
(define (buffer-forward-word! b)
  (mark-forward-word! (buffer-point b)))


(define (buffer-display b)
  (define (line-display l)
    (write l) (newline)
    #;(display (~a "|" (regexp-replace #rx"\n$" (line->string l) "") "|\n")))
  (define (text-display t)
    (for ([l (text-lines t)])
      (line-display l)))
  (define (status-display)
    (displayln (~a "--- buffer: " (buffer-name b) "    " (if (buffer-modified? b) "*" "saved") 
                   " ---")))
  (text-display (buffer-text b))
  (status-display))

(module+ test
  #;(buffer-display illead-buffer))

; buffer-insert-char! : buffer char -> void
;   insert char after point (does not move point)
(define (buffer-insert-char! b c)
  (define m (buffer-point b))
  (define t (buffer-text b))
  (text-insert-char-at-mark! t m b c)
  (buffer-dirty! b))

; buffer-insert-char-after-point! : buffer char -> void
;   insert character and move point
(define (buffer-insert-char-after-point! b k)
  ; note: the position of a single point does not change, but given multiple points...
  (define m (buffer-point b))
  (buffer-insert-char! b k)
  (buffer-adjust-marks-due-to-insertion-after! b (mark-position m) 1))

; buffer-insert-char-before-point! : buffer char -> void
;   insert character and move point
(define (buffer-insert-char-before-point! b k)
  (define m (buffer-point b))
  (buffer-insert-char! b k)
  (buffer-adjust-marks-due-to-insertion-after! b (mark-position m) 1)
  (buffer-move-point! b 1))

; buffer-insert-string-before-point! : buffer string -> void
;   insert string before point (and move point)
(define (buffer-insert-string-before-point! b s)
  ; todo: rewrite to insert entire string in one go
  (for ([c s])
    (if (char=? c #\newline)
        (buffer-break-line! b)
        (buffer-insert-char-before-point! b c))))

(define (buffer-adjust-marks-due-to-insertion-after! b n a)
  (for ([m (buffer-marks b)])
    (mark-adjust-insertion-after! m n a)))

(define (buffer-adjust-marks-due-to-insertion-before! b n a)
  (for ([m (buffer-marks b)])
    (mark-adjust-insertion-before! m n a)))

; buffer-move-point-to-begining-of-line! : buffer -> void
;   move the point to the beginning of the line
(define (buffer-move-point-to-begining-of-line! b)
  (define m (buffer-point b))
  (mark-move-beginning-of-line! m))

; buffer-move-point-to-end-of-line! : buffer -> void
;   move the point to the end of the line
(define (buffer-move-point-to-end-of-line! b)
  (define m (buffer-point b))
  (mark-move-end-of-line! m))

; buffer-length : buffer -> natural
;   return the total length of the text
(define (buffer-length b)
  (text-length (buffer-text b)))

; buffer-break-line! : buffer -> void
;   break line at point
(define (buffer-break-line! b)
  (define m (buffer-point b))
  (define-values (row col) (mark-row+column m))
  (text-break-line! (buffer-text b) row col)
  ; (displayln b)
  (mark-move! m 1)
  (buffer-dirty! b))

; buffer-delete-backward-char! : buffer [natural] -> void
(define (buffer-delete-backward-char! b [count 1])
  ; emacs: delete-backward-char
  (define m (buffer-point b))
  (define t (buffer-text b))
  (for ([i count]) ; TODO improve efficiency!
    (define-values (row col) (mark-row+column m))
    (text-delete-backward-char! t row col)
    (buffer-adjust-marks-due-to-deletion-before! b (mark-position m) 1)
    (mark-move! m -1) ; point
    (buffer-dirty! b)))

(define (buffer-adjust-marks-due-to-deletion-before! b p a)
  (for ([m (buffer-marks b)])
    (mark-adjust-deletion-before! m p a)))

(define (buffer-insert-property! b p)
  (define m (buffer-point b))
  (define t (buffer-text b))
  (define-values (row col) (mark-row+column m))
  (line-insert-property! (dlist-ref (text-lines t) row) p col)
  #;(buffer-dirty! b)) ; xxx

(define (buffer-move-point-to-position! b n)
  (define m (buffer-point b))
  (mark-move-to-position! m n))

; list-next : list any (any any -> boolean)
;   return the element after x,
;   if x is the last element, then return the first element of xs,
;   if x is not found in the list, return #f
(define (list-next xs x =?)
  (match xs
    ['() #f]
    [_   (define first-x (first xs))
         (let loop ([xs xs])
           (cond 
             [(empty? xs)       #f]
             [(=? (first xs) x) (if (empty? (rest xs)) first-x (first (rest xs)))]
             [else              (loop (rest xs))]))]))

(module+ test
  (check-equal? (list-next '(a b c) 'a eq?) 'b)
  (check-equal? (list-next '(a b c) 'b eq?) 'c)
  (check-equal? (list-next '(a b c) 'c eq?) 'a)
  (check-equal? (list-next '(a b c) 'd eq?) #f))


; next-buffer : buffer -> buffer
;   all buffers are in all-buffers, return the one following b
(define (get-next-buffer [b (current-buffer)])
  (list-next all-buffers b eq?))


; buffer-point-marker! : buffer -> mark
;   set new mark at point (i.e. "copy point")
#;(define (buffer-point-marker! b)
    (define p (buffer-point b))
    ...)

;;;
;;; REGIONS
;;;

; region = text between point and the first mark is known as the region.
; set-mark-command sets a mark, and then a region exists


(define (region-beginning [b (current-buffer)])
  (define marks (buffer-marks b))
  (and (not (empty? marks))
       (let ()
         (define mark (first marks))
         (define point (buffer-point b))
         (min (mark-position mark)
              (mark-position point)))))

(define (region-end [b (current-buffer)])
  (define marks (buffer-marks b))
  (and (not (empty? marks))
       (let ()
         (define mark (first marks))
         (define point (buffer-point b))
         (max (mark-position mark)
              (mark-position point)))))

(define (use-region? b)
  (and #t ; (transient-mode-on? b)
       #t ; (mark-active? b)
       (let ()
         (define beg (region-beginning b))
         (define end (region-end b))
         (and beg end (> end beg)))))

(define (region-mark [b (current-buffer)])
  (define marks (buffer-marks b))
  (and (not (empty? marks))
       (first marks)))

; Note: Emacs has delete-active-region, delete-and-extract-region, and, delete-region

; region-delete! : [buffer] -> void
;   Delete all characters in region.
(define (region-delete [b (current-buffer)])
  (when (use-region? b)
    (define marks (buffer-marks b))
    (define mark  (first marks))
    (define point (buffer-point b))
    (cond
      [(mark< mark point) (define n (- (mark-position point) (mark-position mark)))
                          (buffer-delete-backward-char! b n)]
      [(mark< point mark) (define n (- (mark-position mark) (mark-position point)))
                          (buffer-move-point! b n)
                          (buffer-delete-backward-char! b n)]
      [else               (void)])))

;;;
;;; MESSAGES
;;;

(define current-message (make-parameter #f))

(define (message str [msg (current-message)])
  (displayln (list 'message msg))
  (send msg set-label str))

;;;
;;; COMPLETIONS
;;;

(define current-completion-buffer (make-parameter #f))
(define current-completion-window (make-parameter #f))

; (require "trie.rkt")
(require (only-in srfi/13 string-prefix-length))
(define completions '())
(define (add-name-to-completions name)
  (set! completions (sort (cons (~a name) completions) string<?)))
(define (completions-lookup partial-name)
  (define r (regexp (~a "^" partial-name)))
  (filter (λ (name) (regexp-match r name))
          completions))
(define (longest-common-prefix xs)
  (match xs
    ['()                ""]
    [(list x)            x]
    [(list "" y zs ...) ""]
    [(list x  y zs ...) (longest-common-prefix 
                         (cons (substring x 0 (string-prefix-length x y)) zs))]))

(define (completions->text so-far cs)
  (define explanation (list (~a "Completions for: " so-far)))
  (new-text (list->lines (for/list ([c (append explanation cs)]) (~a c "\n")))))

;;;
;;; INTERACTIVE COMMANDS
;;;

;;; Interactive commands are user commands. I.e. the user can
;;; call them via key-bindings or via M-x.
;;; Names of interactive commands are registered in order to 
;;; provide completions for the user.


(define all-interactive-commands-ht (make-hash))
(define (add-interactive-command name cmd)
  (hash-set! all-interactive-commands-ht (~a name) cmd))
(define (lookup-interactive-command cmd-name)
  (hash-ref all-interactive-commands-ht (~a cmd-name) #f))

(define-syntax (define-interactive stx)
  (syntax-parse stx
    [(d-i name:id expr)
     #'(begin
         (add-name-to-completions 'name)
         (define name expr)
         (add-interactive-command 'name name))]
    [(d-i (name:id . args) expr ...)
     #'(begin
         (add-name-to-completions 'name)
         (define (name . args) expr ...)
         (add-interactive-command 'name name))]
    [_ (raise-syntax-error 'define-interactive "bad syntax" stx)]))

;; Names from emacs

(define-interactive (beginning-of-line)   (buffer-move-point-to-begining-of-line! (current-buffer)))
(define-interactive (end-of-line)         (buffer-move-point-to-end-of-line! (current-buffer)))
(define-interactive (backward-char)       (buffer-move-point! (current-buffer) -1))
(define-interactive (forward-char)        (buffer-move-point! (current-buffer) +1))
(define-interactive (previous-line)       (buffer-move-point-up! (current-buffer)))
(define-interactive (next-line)           (buffer-move-point-down! (current-buffer)))
(define-interactive (backward-word)       (buffer-backward-word! (current-buffer)))
(define-interactive (forward-word)        (buffer-forward-word! (current-buffer)))
(define-interactive (move-to-column n)    (buffer-move-to-column! (current-buffer) n)) ; n=num prefix 

(define-interactive (save-buffer)         (save-buffer!    (current-buffer)) (refresh-frame))
(define-interactive (save-buffer-as)      (save-buffer-as! (current-buffer)) (refresh-frame))
(define-interactive (save-some-buffers)   (save-buffer)) ; todo : ask in minibuffer
(define-interactive (beginning-of-buffer [b (current-buffer)]) (buffer-move-point-to-position! b 0))
(define-interactive (end-of-buffer       [b (current-buffer)]) 
  (buffer-move-point-to-position! b (- (buffer-length b) 1)))

(define-interactive (open-file-or-create [path (finder:get-file)])
  (when path ; #f = none selected
    (define b (buffer-open-file-or-create path))
    (set-window-buffer! (current-window) b)
    (current-buffer b)
    (refresh-frame (current-frame))))


(define-interactive (next-buffer) ; show next buffer in current window
  (define w (current-window))
  (define b (get-next-buffer))
  (set-window-buffer! w b)
  (current-buffer b))

(define-interactive (other-window) ; switch current window and buffer
  (define ws (frame-window-tree (current-frame)))
  (define w (list-next ws (current-window) eq?))
  (current-window w)
  (current-buffer (window-buffer w))
  (send (window-canvas w) focus))

(define-interactive (delete-window [w (current-window)])
  (window-delete! w))

(define-interactive (maximize-frame [f (current-frame)]) ; maximize / demaximize frame
  (when (frame? f)
    (define f% (frame-frame% f))
    (when (is-a? f% frame%)
      (send f% maximize (not (send f% is-maximized?))))))

(define-interactive (command-set-mark)
  (displayln (list 'command-set-mark))
  (define b (current-buffer))
  (define p (buffer-point b))
  (define fixed? #f)
  (define name "*mark*")
  (define l (mark-link p))
  (define m (mark b l (mark-position p) name fixed?))
  (set-linked-line-marks! l (set-add (linked-line-marks l) m))
  (set-buffer-marks! b (set-add (buffer-marks b) m))
  m)

; create-new-buffer :  -> void
;   create new buffer and switch to it
(define-interactive (create-new-buffer)
  (define b (new-buffer (new-text) #f (generate-new-buffer-name "Untitled")))
  (set-window-buffer! (current-window) b)
  (current-buffer b)
  (refresh-frame (current-frame)))

; eval-buffer : -> void
;   read the s-expression in the current buffer one at a time,
;   evaluate each ine
;   TODO: Note done: Introduce namespace for each buffer
(define-interactive (eval-buffer)
  (define b (current-buffer))
  (define t (buffer-text b))
  (define s (text->string t))
  (define in (open-input-string s))
  (for ([s-exp (in-port read in)])
    (displayln (eval s-exp))))

; (self-insert-command k) : -> void
;    insert character k and move point
(define ((self-insert-command k))
  ; (display "Inserting: ") (write k) (newline)
  (define b (current-buffer))
  (buffer-insert-char-before-point! b k))

(define-interactive (delete-region [b (current-buffer)])
  (region-delete b))

; backward-delete-char
;   Delete n characters backwards.
;   If n=1 and region is active, delete region.
(define-interactive (backward-delete-char [n 1])
  (define b (current-buffer))
  (if (and (= n 1) (use-region? b))
      (begin
        (delete-region)
        (delete-mark! (region-mark)))
      (buffer-delete-backward-char! b 1)))

(define-interactive (mark-whole-buffer [b (current-buffer)])
  (parameterize ([current-buffer b])
    (end-of-buffer)
    (command-set-mark)
    (beginning-of-buffer)))



;;;
;;; KEYMAP
;;;

;;; Keys aka key sequences are (to a first approximation) represented as strings.
;;    a     "a"
;;    2     "2"
;;    X     "X"
;; ctrl-a   "\C-a"
;; meta-a   "\M-a"

(struct keymap (bindings) #:transparent)

(define (key-event->key event)
  ;(newline)
  #;(begin
      (write (list 'key-event->key
                   'key                (send event get-key-code)
                   'other-shift        (send event get-other-shift-key-code)
                   'other-altgr        (send event get-other-altgr-key-code)
                   'other-shift-altgr  (send event get-other-shift-altgr-key-code)
                   'other-caps         (send event get-other-caps-key-code)))
      (newline))
  (define shift? (send event get-shift-down))
  (define alt?   (send event get-alt-down))
  (define ctrl?  (send event get-control-down))
  (define cmd?   (case (system-type 'os)
                   ; racket reports cmd down as meta down
                   [(macosx) (send event get-meta-down)]
                   ; other systems do not have cmd
                   [else     #f]))  
  (define meta?  (case (system-type 'os)
                   ; use the alt key as meta
                   [(macosx) (send event get-alt-down)]
                   [else     (send event get-meta-down)]))    ; mac: cmd, pc: alt, unix: meta
  ; (displayln (list 'shift shift? 'alt alt? 'ctrl ctrl? 'meta meta? 'cmd cmd?))
  
  (define c      (send event get-key-code))
  ; k = key without modifier
  (define k      (cond
                   [(and ctrl? alt?)  c]
                   [cmd?              c]
                   [alt?              (send event get-other-altgr-key-code)] ; OS X: 
                   [else              c]))
  
  (let ([k (match k 
             ['escape "ESC"] 
             [#\space "space"] 
             [_ k])])
    (cond 
      [(eq? k 'control)      'control] ; ignore control + nothing
      [(and ctrl? (eqv? #\u0000 k))   "C-space"]
      [(or ctrl? alt? meta? cmd?)     (~a (cond 
                                            [ctrl? "C-"]
                                            [meta? "M-"]
                                            [alt?  "A-"]
                                            [cmd?  "D-"]
                                            [else  ""])
                                          k)]
      [(and shift? (eq? k 'shift))    'shift]
      [(and shift? (symbol? k))       (~a "S-" k)]
      [else                           k])))

(define (remove-last xs)
  (if (null? xs) xs
      (reverse (rest (reverse xs)))))



(define global-keymap
  (λ (prefix key)
    ; (write (list prefix key)) (newline)
    
    ; if prefix + key event is bound, return thunk
    ; if prefix + key is a prefix return 'prefix
    ; if unbound and not prefix, return #f
    (define (digits->number ds) (string->number (list->string ds)))
    (define (digit-char? x) (and (char? x) (char<=? #\0 x #\9)))
    ; todo: allow negativ numeric prefix
    (match prefix
      [(list "M-x" more ...)
       (match key
         ["ESC"       (message "")
                      #f]
         [#\backspace (define new (remove-last more))
                      (message (string-append* `("M-x " ,@(map ~a new))))
                      `(replace ,(cons "M-x" new))]
         [#\tab       (define so-far (string-append* (map ~a more)))
                      (define cs     (completions-lookup so-far))
                      (cond 
                        [(empty? cs) (message (~a "M-x " so-far key))
                                     'ignore]
                        [else
                         (define b (current-completion-buffer))
                         (unless b 
                           ;; no prev completions buffer => make a new
                           (define bn "*completions*")
                           (define nb (new-buffer (new-text) #f bn))
                           (current-completion-buffer nb)
                           (set! b nb) 
                           ;; show it new window
                           (split-window-right)   ; both windows show same buffer
                           (define ws (frame-window-tree (current-frame)))
                           (define w  (list-next ws (current-window) eq?))
                           (define ob (window-buffer w))
                           (set-window-buffer! w nb)
                           (current-completion-window ob))
                         ;; text in *completion* buffer
                         (define t (completions->text so-far cs))
                         ;; replace text in completions buffer
                         (mark-whole-buffer b)
                         (delete-region b)
                         (buffer-insert-string-before-point! b (text->string t))
                         ;; replace prefix with the longest unique completion
                         (define pre (longest-common-prefix cs))
                         (message (~a "M-x " pre))
                         (list 'replace (cons "M-x" (string->list pre)))])]
         [#\return    (define cmd-name (string-append* (map ~a more)))
                      (define cmd      (lookup-interactive-command cmd-name))
                      (message "")
                      cmd]
         [_           (message (string-append* `("M-x " ,@(map ~a more) ,(~a key))))
                      'prefix])]
      [(list "C-u" (? digit-char? ds) ...)
       (match key
         [(? digit-char?) 'prefix]
         [#\c             (λ () (move-to-column (digits->number ds)))]
         [else            #f])]
      [(list "ESC") 
       (match key
         [#\b         backward-word]
         [#\f         forward-word]
         [_           #f])]
      [(list "C-x")
       (match key
         [#\0         delete-window]
         [#\2         split-window-below]
         [#\3         split-window-right]
         [#\s         save-some-buffers]
         [#\o         other-window]
         ["C-s"       save-buffer]
         ['right      next-buffer]
         [_           #f])]
      [(list)
       (match key
         ["ESC"       'prefix]
         ["C-x"       'prefix]
         ["C-u"       'prefix]
         ["M-x"       (message "M-x ") 'prefix]
         ['left       backward-char]
         ['right      forward-char]
         ['up         previous-line]
         ['down       next-line]         
         ; Ctrl + something
         ["C-a"       beginning-of-line]
         ["C-b"       backward-char]
         ["C-e"       end-of-line]
         ["C-f"       forward-char]
         ["C-p"       previous-line]
         ["C-n"       next-line]
         ; todo: Make M-< and M-> work
         ; ["M-<"       beginning-of-buffer]
         ["C-<"       beginning-of-buffer]
         ["M->"       end-of-buffer]
         ["C->"       end-of-buffer]
         ; Cmd + something
         ["M-left"    backward-word]
         ["M-right"   forward-word]
         ["M-b"       (λ () (buffer-insert-property! (current-buffer) (property 'bold)))]
         ["M-i"       (λ () (buffer-insert-property! (current-buffer) (property 'italics)))]
         ["M-d"       (λ () (buffer-display (current-buffer)))]
         ["M-s"       save-buffer]
         ["M-S"       save-buffer-as]
         ["M-o"       open-file-or-create]
         ["M-e"       eval-buffer]
         ["M-w"       'exit #;(λ () (save-buffer! (current-buffer)) #;(send frame on-exit) )]
         ["D-w"       'exit] ; Cmd-w (mac only)
         [#\return    (λ () (buffer-break-line! (current-buffer)))]
         [#\backspace backward-delete-char]                                             ; backspace
         [#\rubout    (λ () (error 'todo))]                                             ; delete
         ['home       (λ () (buffer-move-point-to-begining-of-line! (current-buffer)))] ; fn+left
         ['end        (λ () (buffer-move-point-to-end-of-line! (current-buffer)))]      ; fn+right
         ["C-space"   command-set-mark]
         ; place self inserting characters after #\return and friends
         ["space"     (self-insert-command #\space)]
         [(? char? k) (self-insert-command k)]
         [_           #f])]
      [_ #f])))

;;;
;;; STATUS LINE
;;;

; The status line is shown at the bottom om a buffer window.
(define (status-line-hook)
  (define b (current-buffer))
  (define-values (row col) (mark-row+column (buffer-point b)))
  (define save-status (if (buffer-modified? b) "***" "---"))
  (~a save-status  
      "  " "Buffer: "          (buffer-name) "    " "(" row "," col ")"
      "  " "Position: " (mark-position (buffer-point (current-buffer)))
      "  " "Length: "   (buffer-length (current-buffer))))

;;;
;;; WINDOWS
;;;

; A window is an area of the screen used to display a buffer.
; Windows are grouped into frames.
; Each frame contains at least one window.

(define window-ht (make-hash))
(define current-window (make-parameter #f))

; new-window : frame panel buffer -> window
(define (new-window f panel b [parent #f] #:borders [borders #f])
  ; parent is the parent window, #f means no parent parent window
  (define bs (or borders (seteq)))
  (define w (window f panel bs #f parent b))
  (window-install-canvas! w panel)
  w)

; get-buffer-window : [buffer-or-name] -> window
;   return first window in which buffer is displayed
(define (get-buffer-window [buffer-or-name (current-buffer)])
  (define b (get-buffer buffer-or-name))
  (for/first ([w window-ht]
              #:when (eq? (get-buffer (buffer-name (window-buffer w))) b))
    w))

; get-buffer-window-list : [buffer-or-name] -> list-of-windows
;   get list of all windows in which buffer is displayed
(define (get-buffer-window-list [buffer-or-name (current-buffer)])
  (define b (get-buffer buffer-or-name))
  (for/list ([w window-ht]
             #:when (eq? (get-buffer (window-buffer w)) b))
    w))

; REMINDER
;    (struct window (frame canvas parent buffer) #:mutable)
;    (struct horizontal-split-window window (left  right) #:mutable)

; split-window-right : [window] -> void
;   split the window in two, place the new window at the right
;
; Implementation note:
;   The (frame-panel f) holds the panel that display the current windows
;   Make this panel the left son of a new horisontal panel
;   and add a new panel to the right for the new window.
(define (split-window-right [w (current-window)])
  (define f (window-frame w))
  ; the parent p of a window w might be a horizontal- or vertical window
  (define b  (window-buffer w))
  (define bs (window-borders w))
  (define c  (window-canvas w))
  (define p  (window-parent w))
  (define root? (not (window? p)))
  ; the new split window get the parent of our old window
  (define parent-panel (if root? (frame-panel f) (window-panel p)))
  (define pan (new horizontal-panel% [parent parent-panel]))
  (define sp  (horizontal-split-window f pan bs #f p #f w #f))
  ; the old window get a new parent
  (set-window-parent! w sp)
  (send c reparent pan)
  ;; A little space before the next window
  ; (new horizontal-pane% [parent pan] [min-height 2] [stretchable-height #f])
  ; now create the new window to the right
  (define bs2 (set-add bs 'left))
  (define w2 (new-window f pan b sp #:borders bs2))
  (set-horizontal-split-window-right! sp w2)
  ; replace the parent window with the new split window
  (cond 
    [root? ; root window?
     (set-frame-windows! f sp)]
    [(horizontal-split-window? p)
     ; is w a left or a right window?
     (if (eq? (horizontal-split-window-left p) w) 
         (begin
           (set-horizontal-split-window-left!  p sp)
           (send (window-canvas (horizontal-split-window-right p)) reparent parent-panel))
         (set-horizontal-split-window-right! p sp))]
    [(vertical-split-window? p)
     ; is w above or below?
     (if (eq? (vertical-split-window-above p) w) 
         (begin
           (set-vertical-split-window-above! p sp)
           (send (window-canvas (vertical-split-window-below p)) reparent parent-panel))
         (set-vertical-split-window-below! p sp))])
  (send c focus))

(define (split-window-below [w (current-window)])
  (define f (window-frame w))
  ; the parent p of a window w might be a horizontal- or vertical window
  (define b  (window-buffer w))
  (define bs (window-borders w))
  (define c  (window-canvas w))
  (define p  (window-parent w))
  
  (define root? (not (window? p)))
  ; the parent of the new split window (sp), is the parent the window (w) to be split
  (define parent-panel (if root? (frame-panel f) (window-panel p)))
  (define new-panel    (new vertical-panel% [parent parent-panel]))
  (define sp (vertical-split-window f new-panel bs #f p #f w #f))
  ; the split window becomes he parent of the old window
  (set-window-parent! w sp)
  ; this means that the canvas of w, now belongs the the new panel
  (send c reparent new-panel)
  ; The bottom of the split window contains a new window, showing the same buffer
  ; The new window is required to draw the top border
  (define bs2 (set-add bs 'top))
  (define w2 (new-window f new-panel b sp #:borders bs2))
  (set-vertical-split-window-below! sp w2)
  ; The split window takes the place of w in the parent of w
  (cond 
    [root? 
     (set-frame-windows! f sp)]
    [(horizontal-split-window? p)
     ; is w a left or a right window?
     (if (eq? (horizontal-split-window-left p) w) 
         (begin
           (set-horizontal-split-window-left!  p sp)
           (send (window-canvas (horizontal-split-window-right p)) reparent parent-panel))
         (set-horizontal-split-window-right! p sp))]
    [(vertical-split-window? p)
     ; is w above or a?
     (if (eq? (vertical-split-window-above p) w)
         (begin 
           (set-vertical-split-window-above! p sp)
           (send (window-canvas (vertical-split-window-below p)) reparent parent-panel))
         (set-vertical-split-window-below! p sp))]
    [else (error "Internal Error")])
  (send c focus))

(define (left-window?  hw w) (eq? (horizontal-split-window-left  hw) w))
(define (right-window? hw w) (eq? (horizontal-split-window-right hw) w))
(define (above-window? hw w) (eq? (vertical-split-window-above   hw) w))
(define (below-window? hw w) (eq? (vertical-split-window-below   hw) w))

; replace : any any list -> list
;   copy zs but replace occurences of x with y
(define (replace x y zs)
  (for/list ([z (in-list zs)])
    (if (eq? z x) y z)))

(define (window-delete! w)
  (define fp (window-panel (frame-windows (current-frame))))
  (send fp begin-container-sequence)
  (define (window-backend w)
    ; split-windows are backed by a panel holding subwindows,
    ; whereas a single window is backed by a canvas
    (if (split-window? w) (window-panel  w) (window-canvas w)))
  ; to delete the window w, it must be removed from its parent
  (define p (window-parent w))
  (displayln (list 'parent p))
  ; only split windows can hold subwindows
  (unless (split-window? p)
    (error 'window-delete "can't delete window"))
  ;; since the parent is a split window, it must hold another window:
  (define ow ; other window
    (cond [(vertical-split-window? p) 
           (if (above-window? p w)
               (vertical-split-window-below p)
               (vertical-split-window-above p))]
          [(horizontal-split-window? p) 
           (if (left-window? p w)
               (horizontal-split-window-right p)
               (horizontal-split-window-left p))]
          [else (error 'window-delete! "internal error")]))
  ;; The sole purpose of the parent is to hold w and ow, 
  ;; since w is to be deleted, the parent p is no longer needed.
  ;; To replace p with ow, we need to grab the grand parent and replace parent with other window
  (define gp (window-parent p))
  (set-window-parent! ow gp)
  (cond [(horizontal-split-window? gp)
         (if (left-window? gp p)
             (set-horizontal-split-window-left!  gp ow)
             (set-horizontal-split-window-right! gp ow))]
        [(vertical-split-window? gp)
         (if (above-window? gp p)
             (set-vertical-split-window-above! gp ow)
             (set-vertical-split-window-below! gp ow))]
        [else (void)])    
  ;; if the current window is deleted, we need to make a new window the current one.
  (when (eq? (current-window) w) (current-window ow))
  (current-buffer (window-buffer (current-window)))
  ;; The window structures are now updated, but the gui panels need to be updated too.
  (cond
    [(eq? gp 'root)
     (set-window-borders! ow '()) ; root has no borders
     (define f (window-frame w))
     (set-frame-windows! f ow)
     (define panel (frame-panel f))
     (send panel change-children  (λ (cs) '()))
     (send (window-backend ow) reparent panel)]
    [else ; gp is a split window
     (set-window-borders! ow (window-borders p))
     (define panel (window-panel gp))
     ; make ow a child of the grand parent
     (send (window-backend ow) reparent panel)
     ; now the ow is last child, so we need to move to the where p is
     (send panel change-children 
           (λ (cs) (replace (window-backend p) (window-backend ow)
                            (filter (λ(c) (not (eq? c (window-backend ow))))
                                    cs))))])
  (send fp end-container-sequence)
  ;; send keyboard focus to other window
  (send (window-backend ow) focus))

;;;
;;; FRAMES
;;;

(define current-frame (make-parameter #f))

(define (refresh-frame [f (current-frame)])
  (when (and f (frame? f))
    (render-frame f)))

(define (frame-window-tree [f (current-frame)])
  (define (loop w)
    (match w
      [(horizontal-split-window f _ _ c p b l r)    (append (loop l) (loop r))]
      [(vertical-split-window   f _ _ c p b u l)    (append (loop u) (loop l))]
      [(window frame panel borders canvas parent buffer) (list w)]))
  (flatten (loop (frame-windows f))))

;;;
;;; COLORS
;;;

(define (hex->color x)
  (define red   (remainder           x        256))
  (define green (remainder (quotient x   256) 256))
  (define blue  (remainder (quotient x 65536) 256))
  (make-object color% red green blue))

(define base03  (hex->color #x002b36)) ; brblack    background   (darkest)
(define base02  (hex->color #x073642)) ; black      background 
(define base01  (hex->color #x586e75)) ; brgreen    content tone (darkest)
(define base00  (hex->color #x657b83)) ; bryellow   content tone

(define base0   (hex->color #x839496)) ; brblue     content tone
(define base1   (hex->color #x93a1a1)) ; brcyan     content tone (brigtest)
(define base2   (hex->color #xeee8d5)) ; white      background
(define base3   (hex->color #xfdf6e3)) ; brwhite    background   (brightest)

(define yellow  (hex->color #xb58900)) ; yellow     accent color33
(define orange  (hex->color #xcb4b16)) ; brred      accent color
(define red     (hex->color #xdc322f)) ; red        accent color
(define magenta (hex->color #xd33682)) ; magenta    accent color
(define violet  (hex->color #x6c71c4)) ; brmagenta  accent color
(define blue    (hex->color #x268bd2)) ; blue       accent color
(define cyan    (hex->color #x2aa198)) ; cyan       accent color
(define green   (hex->color #x859900)) ; green      accent color

;;;
;;; FONT
;;;

(define font-style  (make-parameter 'normal))  ; style  in '(normal italic)
(define font-weight (make-parameter 'normal))  ; weight in '(normal bold)
(define font-size   (make-parameter 16))
(define font-family (make-parameter 'modern))  ; fixed width
(define (use-default-font-settings)
  (font-style  'normal)
  (font-weight 'normal)
  (font-size   16)
  (font-family 'modern))
(define font-ht (make-hash))                   ; (list size family style weight) -> font  
(define (get-font)
  (define key (list (font-size) (font-family) (font-style) (font-weight)))
  (define font (hash-ref font-ht key #f))
  (unless font
    (set! font (make-object font% (font-size) (font-family) (font-style) (font-weight)))
    (hash-set! font-ht key font))
  font)
(define (toggle-bold)    (font-weight (if (eq? (font-weight) 'normal) 'bold   'normal)))
(define (toggle-italics) (font-style  (if (eq? (font-style)  'normal) 'italic 'normal)))
(define default-fixed-font  (get-font))

;;;
;;; GUI
;;;

(define current-render-points-only? (make-parameter #f))
(define current-show-points?        (make-parameter #f))


(define (render-buffer w b dc xmin xmax ymin ymax)
  (unless (current-render-points-only?)
    (when b
      ;; Highlightning for region between mark and point
      (define text-background-color (send dc get-text-background))
      (define region-highlighted-color magenta)
      (define (set-text-background-color highlight?)
        (define background-color (if highlight? region-highlighted-color text-background-color))
        (send dc set-text-background background-color))
      ;; Dimensions
      (define width  (- xmax xmin))
      (define height (- ymax ymin))
      (define fs (font-size))
      (define ls (+ fs 1)) ; linesize -- 1 pixel for spacing
      ;; Placement of point relative to lines on screen
      (define num-lines-on-screen (max 0 (quotient height ls)))
      (define-values (row col)    (mark-row+column (buffer-point  b)))
      (define last-row-on-screen  (min row num-lines-on-screen))
      (define first-row-on-screen (max 0 (- row num-lines-on-screen)))
      (define num-lines-to-skip   first-row-on-screen)
      ;; Placement of region
      (define-values (reg-begin reg-end)
        (if (use-region? b) (values (region-beginning b) (region-end b)) (values #f #f)))
      ; (displayln (list 'first-line first-row-on-screen 'last-line last-row-on-screen))
      (send dc suspend-flush)  
      ; draw-string : string real real -> real
      ;   draw string t at (x,y), return point to draw next string
      (define (draw-string t x y)
        (define-values (w h _ __) (send dc get-text-extent t))
        (send dc draw-text t x y)
        (+ x w))
      ; draw text
      (for/fold ([y ymin] [p 0]) ; p the position of start of line
                ([l #;(drop (dlist->list (text-lines (buffer-text b))) num-lines-to-skip)
                    (text-lines (buffer-text b))]
                 [i num-lines-on-screen])
        (define strings (line-strings l))
        (define n (length strings))
        (define (last-string? i) (= i (- n 1)))
        (define (sort-numbers xs) (sort xs <))
        (for/fold ([x xmin] [p p]) ([s strings] [i (in-range n)])
          ; p is the start position of the string s
          (match s
            [(? string?)
             (define sn (string-length s))
             ; find positions of points and marks in the string
             (define positions-in-string
               (sort-numbers
                (append (for/list ([m (buffer-marks b)]  #:when (<= p (mark-position m) (+ p sn)))
                          (mark-position m))
                        (for/list ([m (buffer-points b)] #:when (<= p (mark-position m) (+ p sn)))
                          (mark-position m)))))
             ; split the string at the mark positions (there might be a color change)
             (define start-positions (cons p positions-in-string))
             (define end-positions   (append positions-in-string (list (+ p sn))))
             (define substrings      (map (λ (start end) (substring s (- start p) (- end p)))
                                          start-positions end-positions))
             ; draw the strings one at a time
             (define-values (next-x next-p)
               (for/fold ([x x] [p p]) ([t substrings])
                 (when (and reg-begin (= reg-begin p)) (set-text-background-color #t))
                 (when (and reg-end   (= reg-end   p)) (set-text-background-color #f))
                 (define u ; remove final newline if present
                   (or (and (not (equal? t ""))
                            (char=? (string-ref t (- (string-length t) 1)) #\newline)
                            (substring t 0 (max 0 (- (string-length t) 1))))
                       t))
                 (values (draw-string u x y) (+ p (string-length t)))))
             ; return the next x position
             (values next-x next-p)]        
            [(property 'bold)     (toggle-bold)    (send dc set-font (get-font)) x]
            [(property 'italics)  (toggle-italics) (send dc set-font (get-font)) x]
            [_ (displayln (~a "Warning: Got " s)) x]))
        (values (+ y ls)
                (+ p (line-length l))))
      ; get point and mark height
      ;(define font-width  (send dc get-char-width))
      ;(define font-height (send dc get-char-height))
      (define-values (font-width font-height _ __) (send dc get-text-extent "M"))
      ; draw marks (for debug)
      #;(begin
          (define old-pen (send dc get-pen))
          (define new-pen (new pen% [color yellow]))
          (send dc set-pen new-pen)
          (for ([p (buffer-marks b)])
            (define-values (r c) (mark-row+column p))
            (define x (+ xmin (* c    font-width)))
            (define y (+ ymin (* r (+ font-height -2)))) ; why -2 ?
            (when (and (<= xmin x xmax) (<= ymin y) (<= y (+ y font-height -1) ymax))
              (send dc draw-line x y x (min ymax (+ y font-height -1)))))
          (send dc set-pen old-pen))
      ; resume flush
      (send dc resume-flush)))
  ; draw points
  (render-points w b dc xmin xmax ymin ymax))

(define (render-points w b dc xmin xmax ymin ymax)
  (define points-on-pen  (new pen% [color text-color]))
  (define points-off-pen (new pen% [color background-color]))
  ; get point and mark height
  (define-values (font-width font-height _ __) (send dc get-text-extent "M"))
  (when b
    (define active? (send (window-canvas w) has-focus?))
    (when active?
      (define cm (current-inexact-milliseconds))
      (define on? (current-show-points?))
      (for ([p (buffer-points b)])
        (define-values (r c) (mark-row+column p))
        (define x (+ xmin (* c    font-width)))
        (define y (+ ymin (* r (+ font-height -2)))) ; why -2 ?
        (when (and (<= xmin x xmax) (<= ymin y) (<= y (+ y font-height -1) ymax))
          (define old-pen (send dc get-pen))
          (send dc set-pen (if on? points-on-pen points-off-pen))
          (send dc draw-line x y x (min ymax (+ y font-height -1)))
          (send dc set-pen old-pen))))))


(define (render-window w)
  (define c  (window-canvas w))
  (define dc (send c get-dc))
  ;; sane defaults
  (use-default-font-settings)
  (send dc set-font default-fixed-font)
  (send dc set-text-mode 'solid) ; solid -> use text background color
  ; (send dc set-background "white")
  (unless (current-render-points-only?)
    (send dc clear))
  
  (send dc set-text-background background-color)
  (send dc set-text-foreground text-color)
  
  ;; render buffer
  (define xmin 0)
  (define xmax (send c get-width))
  (define ymin 0)
  (define ymax (send c get-height))
  
  (define bs (window-borders w))
  ; bordersize is 2 ?
  (when (set-member? bs 'top)
    (send dc draw-line 0 0 xmax 0)
    (set! ymin (+ ymin 1)))
  (when (set-member? bs 'left)
    (send dc draw-line 0 0 0 ymax)
    (set! xmin (+ xmin 1)))
  (render-buffer w (window-buffer w) dc xmin xmax ymin ymax))

(define (render-windows win)
  (match win
    [(horizontal-split-window _ _ _ _ _ _ left  right) 
     (render-windows left)
     (render-windows right)]
    [(vertical-split-window _ _ _ _ _ _ upper lower)
     (render-windows upper)
     (render-windows lower)]
    [(window frame panel borders canvas parent buffer)
     (render-window  win)]
    [_ (error 'render-window "got ~a" win)]))

(define (frame->windows f)
  (define (loop ws)
    (match ws
      [(vertical-split-window _ _ _ _ _ _ upper lower)
       (append (loop upper) (loop lower))]
      [(horizontal-split-window _ _ _ _ _ _ left right)
       (append (loop left) (loop right))]
      [w (list w)]))
  (loop (frame-windows f)))

(define (render-frame f)
  ;; show name of buffer with keyboard focus as frame title
  (define f% (frame-frame% f))
  (define ws (frame->windows f))
  (define w  (for/or ([w ws])
               (and (send (window-canvas w) has-focus?)
                    w)))
  (when (window? w)
    (define n (buffer-name (window-buffer w)))
    (unless (equal? n (send f% get-label))
      (send f% set-label n)))
  ;; render windows
  (render-windows (frame-windows f)))

;;; Mini Canvas
; The bottom line of each frame is a small canvas.
; The mini canvas can be used to display either the Echo Area 
; or a Mini Buffer.

;;; ECHO AREA

; The Echo Area uses the the mini canvas at the bottom of the 
; frame to give messages to the user.

;;; MINI BUFFER

; The mini buffer is a buffer displayed in the mini canvas.
; Most buffer operations are avaialble, but it can not be split.
; <tab>, <space> and <return> are usually bound to completion 
; operations in a minibuffer.

#;(define (message format-string . arguments)
    ; TODO
    ; Display the message in the mini-buffer,
    ; add the message to the *Messages* buffer.
    (define msg (apply format format-string arguments))
    #;(send (frame-echo-area f) set-message s)
    1)

;;; COLORS
(define background-color base1)
(define text-color       base03)

; create-window-canvas : window panel% -> canvas
; this-window 
;   the non-gui structure representing the window used to display a buffer.
; f
;   the non-gui structure representing the frame of the window
; panel
;   the panel which the canvas has as parent
(define (window-install-canvas! this-window panel)
  (define f (window-frame this-window))
  ;;; PREFIX 
  ; keeps track of key pressed so far
  (define prefix '())
  (define (add-prefix! key) (set! prefix (append prefix (list key))))
  (define (clear-prefix!)   (set! prefix '()))
  
  (define window-canvas%
    (class canvas%
      ;; Buffer
      (define the-buffer #f)
      (define (set-buffer b) (set! the-buffer b))
      (define (get-buffer b) the-buffer)
      ;;; Focus Events
      (define/override (on-focus event)
        (define w this-window)
        (define b (window-buffer w))
        ; (displayln (list 'on-focus (buffer-name b)))
        (current-buffer b)
        (current-window w))
      ;; Key Events
      (define/override (on-char event)
        ; TODO syntax  (with-temp-buffer body ...)
        (define key-code (send event get-key-code))
        (unless (equal? key-code 'release)
          (define key (key-event->key event))
          ; (displayln (list 'key key 'shift (get-shift-key-code event)))
          ; (send msg set-label (~a "key: " key))
          (match (global-keymap prefix key)
            [(? procedure? thunk)  (clear-prefix!) (thunk)]
            [(list 'replace pre)   (set! prefix pre)]
            ['prefix               (add-prefix! key)]
            ['ignore               (void)]
            ['exit                ; (save-buffer! (current-buffer))
             ; TODO : Ask how to handle unsaved buffers
             (send (frame-frame% f) on-exit)]
            ['release             (void)]
            [_                    (unless (equal? (send event get-key-code) 'release)
                                    (clear-prefix!))]))
        ; todo: don't trigger repaint on every key stroke ...
        (send canvas on-paint))
      ;; Rendering
      (public on-paint-points)
      (define (on-paint-points on?) ; render points only
        (parameterize ([current-render-points-only? #t]
                       [current-show-points?        on?])
          (render-frame f)))     
      (define/override (on-paint) ; render everything
        (parameterize ([current-show-points? #t])
          (render-frame f)))
      ; (define dc (send canvas get-dc))
      ; reset drawing context
      
      ; (render-frame (window-frame this-window) dc) XXX
      ; uddate status line
      ; (display-status-line (status-line-hook)) ; XXX TODO XXX 
      (super-new)))
  (define canvas (new window-canvas% [parent panel]))
  (set-window-canvas! this-window canvas)
  (send canvas min-client-width  20)
  (send canvas min-client-height 20)
  ; start update-points thread
  (thread (λ () (let loop ([on? #t])
                  (sleep/yield 0.5)
                  (send canvas on-paint-points on?)
                  (loop (not on?)))))
  canvas)

(define make-frame frame)
(define (frame-install-frame%! this-frame)
  ;;; FRAME SIZE
  (define min-width  800)
  (define min-height 800)
  ;;; FRAME  
  (define frame (new frame% [label "Editor"] [style '(fullscreen-button)]))
  (set-frame-frame%! this-frame frame)
  (define msg (new message% [parent frame] [label "No news"]))
  (current-message msg)
  (send msg min-width min-width)
  ;;; MENUBAR
  (define (create-menubar)
    (define-syntax (new-menu-item stx)
      (syntax-parse stx  ; add menu item to menu
        [(_ par l sc scm cb) 
         #'(let ([m scm])
             (if m
                 (new menu-item% [label l] [parent par] [shortcut sc] [callback cb] 
                      [shortcut-prefix (if (list? m) m (list m))])
                 (new menu-item% [label l] [parent par] [shortcut sc] [callback cb])))]))
    (define mb (new menu-bar% (parent frame)))
    ;; File Menu
    (define fm (new menu% (label "File") (parent mb)))
    (new-menu-item fm "New File"   #\n #f           (λ (_ e) (create-new-buffer)))
    (new-menu-item fm "Open"       #\o #f           (λ (_ e) (open-file-or-create)))
    (new-menu-item fm "Save"       #\s #f           (λ (_ e) (save-buffer)))
    (new-menu-item fm "Save As..." #\s '(shift cmd) (λ (_ e) (save-buffer-as)))
    ;; Help Menu
    (new menu% (label "Help") (parent mb))) 
  (create-menubar)
  ;; PANEL
  ; The holds contains the shown window 
  (define panel (new vertical-panel% 
                     [parent frame]
                     [min-width min-width]
                     [min-height 50]))
  (set-frame-panel! this-frame panel)
  ;;; CANVAS
  ; Non-split windows are rendered into an associated canvas.
  ; (Split windows holds panels of windows and/or subpanels)
  ; Buffers, mini buffers and the echo area are rendered into 
  ; into the canvas of the window to which they belong.
  
  ; (define canvas 'todo #;(create-window-canvas w))
  ; (set-frame-canvas! this-frame canvas) ; XXX
  ;; Status line
  (define status-line (new message% [parent frame] [label "Welcome"]))
  (send status-line min-width min-width)
  (define (display-status-line s) (send status-line set-label s))
  (display-status-line "Don't panic")
  (send frame show #t)
  
  ; (struct frame (frame% panel windows mini-window) #:mutable)
  (make-frame frame panel #f #f))

(module+ test
  (define ib illead-buffer)
  (current-buffer ib)
  (define f  (frame #f #f #f #f))
  (frame-install-frame%! f) ; installs frame% and panel
  
  (define p (frame-panel f))
  (define w (new-window f p ib 'root))
  
  ;(define sp (vertical-split-window f #f #f #f #f #f #f))  
  ; (define w  (window f #f c sp ib))
  ; (define c2 #f)
  ; (define w2 (window f #f c2 sp (get-buffer "*scratch*")))
  ; (set-vertical-split-window-above! sp w)
  ; (set-vertical-split-window-below! sp w2)
  ; (set-frame-windows! f sp)
  (set-frame-windows! f w)
  (current-window w)
  (current-frame f)
  
  (send (window-canvas w) focus))


(define (display-file path)
  (with-input-from-file path
    (λ ()
      (for ([l (in-lines)])
        (displayln l)))))
