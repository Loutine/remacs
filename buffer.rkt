#lang racket
(provide (all-defined-out))

(require (for-syntax syntax/parse)
         "parameters.rkt"
         "representation.rkt"
         "text.rkt"
         "dlist.rkt"
         "mark.rkt"
         "line.rkt"
         "region.rkt")
;;;
;;; BUFFER
;;;

(module+ test (require rackunit))

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

(module* buffer-top #f
  (provide (rename-out [buffer-top #%top]))
  ; (require (for-syntax racket/base syntax/parse))
  (define-syntax (buffer-top stx)
    (syntax-parse stx
      [(_ . id:id)
       #'(let ()
           (define b (current-buffer))
           (cond
             [(ref-buffer-local b 'id #f) => values]
             [else (lookup-default 'id)]))])))

(require syntax/location)
(define path-to-buffer-top (quote-module-path buffer-top))

; new-buffer : -> buffer
;   create fresh buffer without an associated file
(define (new-buffer [text (new-text)] [path #f] [name (generate-new-buffer-name "buffer")])
  (define locals (make-base-empty-namespace))
  (parameterize ([current-namespace locals])
    (namespace-require 'racket/base)
    ; (eval `(require ,path-to-buffer-top))
    )
  (define b (buffer text name path 
                    '()   ; points
                    '()   ; marks
                    '()   ; modes 
                    0     ; cur-line
                    0     ; num-chars
                    0     ; num-lines
                    #f    ; modified?
                    locals))  ; locals
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

(define scratch-text
  '("Welcome to remacs, an Emacs style editor implemented in Racket.\n"
    "The editor is still a work-in-progress.\n\n"
    "\n"
    "Search for keymap in the source to see the available keybindings.\n"
    "    C-x 2      splits the window in two vertically\n"
    "    C-x 3      splits the window in two horizontally\n"
    "    C-x right  is bound to next-buffer\n\n" 
    "\n"
    "Happy Rackteering\n"
    "/soegaard"))

(define scratch-buffer (new-buffer (new-text (list->lines scratch-text)) #f "*scratch*"))
(current-buffer scratch-buffer)
; (define current-buffer (make-parameter scratch-buffer))

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
(require framework)
(define (save-buffer! b)
  (define file (buffer-path b))
  (unless file
    (set! file (finder:put-file))
    (set-buffer-name! b (path->string file)))
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
    (set-buffer-name! b (path->string file))
    (save-buffer! b)))

(define (refresh-frame)
  ((current-refresh-frame)))

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

; buffer-move-point-to-beginning-of-line! : buffer -> void
;   move the point to the beginning of the line
(define (buffer-move-point-to-beginning-of-line! b)
  (define m (buffer-point b))
  (mark-move-beginning-of-line! m))

; buffer-move-point-to-end-of-line! : buffer -> void
;   move the point to the end of the line
(define (buffer-move-point-to-end-of-line! b)
  (define m (buffer-point b))
  (mark-move-end-of-line! m))


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

(define (buffer-insert-property-at-point! b p)
  (define m (buffer-point b))
  (define t (buffer-text b))
  (define-values (row col) (mark-row+column m))
  (line-insert-property! (dlist-ref (text-lines t) row) p col)
  #;(buffer-dirty! b))

(define (buffer-insert-property! b p [p-end p])
  ; if the region is active, the property is inserted
  ; before and after the region (consider: are all properties toggles?)
  ; if there are no region the property is simply inserted
  (cond
    [(use-region? b)
     (define rb (region-beginning b))
     (define re (region-end b))
     (define m (buffer-point b))
     (define old (mark-position m))
     (mark-move-to-position! m rb)
     (buffer-insert-property-at-point! b p)
     (mark-move-to-position! m re)
     (buffer-insert-property-at-point! b p-end)
     (mark-move-to-position! m old)]
    [else
     (buffer-insert-property-at-point! b p)]))

(define (buffer-move-point-to-position! b n)
  (define m (buffer-point b))
  (mark-move-to-position! m n))

(define (buffer-set-mark [b (current-buffer)])
  ; make new mark at current point and return it
  (define p (buffer-point b))
  (define fixed? #f)
  (define active? #t)
  (define name "*mark*")
  (define l (mark-link p))
  (define m (mark b l (mark-position p) name fixed? active?))
  (set-linked-line-marks! l (set-add (linked-line-marks l) m))
  (set-buffer-marks! b (set-add (buffer-marks b) m))
  (mark-activate! m)
  m)

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
