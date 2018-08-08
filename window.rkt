#lang racket/base
(provide (all-defined-out))
(define (debug-display x) (void x))

(require racket/class racket/format racket/list racket/match racket/math racket/set
         racket/gui/base
         "buffer.rkt"
         "buffer-locals.rkt"
         "canvas.rkt"
         "colors.rkt"
         "command-loop.rkt"
         "frame.rkt"
         "key-event.rkt"
         "locals.rkt"
         "mark.rkt"
         "message.rkt"
         "parameters.rkt"
         "render.rkt"
         "representation.rkt"
         "status-line.rkt")

(define (buffer-local-keymap [b (current-buffer)])
  (ref-buffer-local 'local-keymap b #f))

;;;
;;; WINDOWS
;;;

; A window is an area of the screen used to display a buffer.
; Windows are grouped into frames.
; Each frame contains at least one window.

(define all-windows '())

; new-window : frame panel buffer -> window
(define (new-window f panel b [parent #f] #:borders [borders #f])
  ; parent is the parent window, #f means no parent parent window
  (define bs (or borders (seteq)))
  (define point (copy-mark (buffer-point b)))
  (mark-move! (buffer-end-mark b) (buffer-length b))
  (define w (window f panel bs #f parent b point))
  (window-install-canvas! w panel)
  (set! all-windows (cons w all-windows))
  w)

; get-buffer-window : [buffer-or-name] -> window
;   return first window in which buffer is displayed
(define (get-buffer-window [buffer-or-name (current-buffer)])
  (define b (get-buffer buffer-or-name))
  (for/first ([w all-windows]
              #:when (eq? (get-buffer (buffer-name (window-buffer w))) b))
    w))

; get-buffer-window-list : [buffer-or-name] -> list-of-windows
;   get list of all windows in which buffer is displayed
(define (get-buffer-window-list [buffer-or-name (current-buffer)])
  (define b (get-buffer buffer-or-name))
  (for/list ([w all-windows]
             #:when (eq? (get-buffer (window-buffer w)) b))
    w))

; get-buffer-frame-list : [buffer-or-name] -> list-of-frame
;   get list of all frames in which buffer is displayed
(define (get-buffer-frame-list [buffer-or-name (current-buffer)])
  (define ws (get-buffer-window-list buffer-or-name))
  (set->list (list->set (map window-frame ws))))

(define (get-buffer-frame [buffer-or-name (current-buffer)])
  (define fs (get-buffer-frame-list buffer-or-name))
  (if (empty? fs) #f (first fs)))

(define (refresh-buffer [buffer-or-name (current-buffer)])
  (refresh-frame (get-buffer-frame buffer-or-name)))
(current-refresh-buffer refresh-buffer)

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
  (unless f (error))
  (parameterize ([current-eventspace (send (frame-frame% f) get-eventspace)])
    ; the parent p of a window w might be a horizontal or vertical window
    (define b  (window-buffer w))
    (define bs (window-borders w))
    (define c  (window-canvas w))
    (define p  (window-parent w))    
    (define root? (not (window? p)))    
    ; the new split window get the parent of our old window
    (define parent-panel (if root? (frame-panel f) (window-panel p)))
    (define pan (new horizontal-panel% [parent parent-panel]))
    (define sp  (horizontal-split-window f pan bs #f p  #f #f w #f))
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
    (send c focus)))

(define (split-window-below [w (current-window)])
  (define f (window-frame w))
  (parameterize ([current-eventspace (send (frame-frame% f) get-eventspace)])
    ; the parent p of a window w might be a horizontal- or vertical window
    (define b  (window-buffer w))
    (define bs (window-borders w))
    (define c  (window-canvas w))
    (define p  (window-parent w))
  
    (define root? (not (window? p)))
    ; the parent of the new split window (sp), is the parent the window (w) to be split
    (define parent-panel (if root? (frame-panel f) (window-panel p)))
    (define new-panel    (new vertical-panel% [parent parent-panel]))
    (define sp (vertical-split-window f new-panel bs #f p #f #f #f #f w #f))
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
    (send c focus)))

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
  (set! all-windows (remq w all-windows))
  (define fp (window-panel (frame-windows (current-frame))))
  (send fp begin-container-sequence)
  (define (window-backend w)
    ; split-windows are backed by a panel holding subwindows,
    ; whereas a single window is backed by a canvas
    (if (split-window? w) (window-panel  w) (window-canvas w)))
  ; to delete the window w, it must be removed from its parent
  (define p (window-parent w))
  ; only split windows can hold subwindows
  (unless (split-window? p)
    (print p)
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


(define (prepare-colors w)
  (define b (window-buffer w))
  (localize ([current-window w] [current-buffer b])
    (maybe-recenter-top-bottom #f w) ; set start and end mark
    (when (local color-buffer)
      (send-command
       (localize ([current-buffer b] [current-window w])
         (define from (or (position (window-start-mark w)) 0))
         (define to   (min ;(or (position (window-end-mark w)) +inf.0)
                           (- (buffer-length b) 1)))
         ((local color-buffer) b (max 0 from) (max 0 to)))))))

(current-prepare-color prepare-colors)


; window-install-canvas! : window panel% -> canvas
; this-window : the non-gui structure representing the window used to display a buffer.
; panel       : the panel which the canvas has as parent
(define (window-install-canvas! this-window panel)
  ;; Adjust eventspace.
  ; The parameter current-eventspace is normally used, but since it is a
  ; parameter, it might not be referring to the original namespace.
  (define top (send panel get-top-level-window))
  (define es  (send top   get-eventspace))
  (parameterize ([current-eventspace es])
    ;; 
    (define f (window-frame this-window))  
    ;;; PREFIX 
    ; keeps track of key pressed so far
    (define prefix '())
    (define (add-prefix! key) (set! prefix (append prefix (list key))))
    (define (clear-prefix!)   (set! prefix '()))
  
    (define handle-mouse
      (let ([left-down? #f]
            [last-left-click-row #f] [last-left-click-col #f])
        (λ (e type)
          (send-command
           (unless (member type '(left-down left-up motion))
             (error "expected 'left-down, 'left-up or 'motion got: ~a" type))
           ; a left click will move the point to the location clicked
           (define (exact r) (exact-floor r))
           (define-values (x y) (values (exact (send e get-x)) (exact (send e get-y))))
           (define c  (window-canvas this-window))
           (define dc (send c get-dc))
           ; Canvas Dimensions
           (define-values (xmin xmax ymin ymax) (canvas-dimensions c))
           ;; Dimensions
           (define width  (- xmax xmin))
           (define height (- ymax ymin))
           (define fs (exact (font-size)))
           (define ls (exact (line-size)))
           (define num-lines-on-screen   (max 0 (quotient height ls)))
           (define n num-lines-on-screen)    
           (define-values (w h _ __) (send dc get-text-extent "x")) ; font width and height
           (set! h (exact h)) (set! w (exact w))
           ; compute screen row and column
           (define screen-row (quotient y ls))
           (define screen-col (quotient x w))      
           ; find first row displayed on screen
           (define start-mark (window-start-mark this-window))
           (define start-row  (mark-row start-mark))
           ; Add start-row and row to get the buffer start row
           (define b (window-buffer this-window))
           (define-values (row col)
             (screen-coordinates->text-coordinates start-row screen-row screen-col this-window b))
           ; (define row (+ start-row screen-row))
           ; (define col screen-col)  ; TODO: change this when wrapping of long lines gets support
           (cond        
             [(eq? type 'left-down)
              ; register where left mouse clicked happened
              ; wait for left-up or motion to do anything
              (set! left-down? #t)
              (set! last-left-click-row row)
              (set! last-left-click-col col)]
             [(or (eq? type 'left-up)
                  (and (eq? type 'motion) left-down?))
              ; register mouse up
              (when (eq? type 'left-up) (set! left-down? #f))
              ; for both up and motion, create region
              (define m (get-mark))
              (unless m ; no mark so far, make one
                (push-mark)
                (set! m (get-mark)))
              (define b (window-buffer this-window))
              (define p (buffer-point b))
              (when (and m (mark-active? m))
                (mark-deactivate! m))
              (cond   ; no drag
                [(and (equal? last-left-click-row row) (equal? last-left-click-col col)) 
                 (mark-move-to-row+column! p row col)]
                [else ; mouse dragged
                 (mark-move-to-row+column! p row col)
                 (unless m (buffer-set-mark-to-point b) (set! m (get-mark)))
                 (when (and last-left-click-row last-left-click-col)
                   (mark-move-to-row+column! m last-left-click-row last-left-click-col))
                 (mark-activate! m)])
              (maybe-recenter-top-bottom #t this-window)
              (refresh-frame)])))))
    
    (define window-canvas%
      (class canvas%
        (inherit has-focus?)
        ;; Buffer
        ;(define the-buffer #f)
        ;(define (set-buffer b) (set! the-buffer b))
        ;(define (get-buffer b) the-buffer)
        ;;; Focus Events
        (define/override (on-event e) ; mouse events
          (define b (current-buffer))
          (define w this-window)
          (define f (current-frame))
          (send-command
           (localize ([current-buffer b]
                      [current-window w]
                      [current-frame  f])
             (define type (send e get-event-type))
             ;(displayln type)
             (case type
               [(left-down) (handle-mouse e 'left-down)]
               [(left-up)   (handle-mouse e 'left-up)]
               [(motion)    (handle-mouse e 'motion)]))))
        (define/override (on-focus on?)
          (unless (boolean? on?) (error 'on-focus "sigh"))
          (send-command
           (when on?
             (define w this-window)
             (define b (window-buffer w))
             (current-buffer b)
             (current-window w))))
        ;; Key Events
        (define/override (on-char event)
          ; (define b (current-buffer))
          ; (define w this-window)
          ; (define f (current-frame))
          (send-command
           (begin ; [current-buffer b]
             ; [current-window w]
             ; [current-frame  f]
             ; NOTE: Menu shorts cuts are intercepted and on-char is never called.
             (current-point-color point-colors) ; make points visible when keyboard is active
             ; TODO syntax  (with-temp-buffer body ...)
             (define key-code (send event get-key-code))
             (unless (equal? key-code 'release)
               (define key (key-event->key event))
               (message (~a "key: " key))
               (unless (member key '(control rcontrol))
                 (define local-keymap (buffer-local-keymap (current-buffer)))
                 (define binding      (or (and local-keymap (local-keymap prefix key))
                                          ((current-global-keymap) prefix key)
                                          ; If A-<key> is unbound, then use the character as-is.
                                          ; This makes A-a insert å.
                                          (and (char? key-code)
                                               ; make sure C-[a-z] doesn't produce a character if
                                               ; the key combination is unbound
                                               (not (regexp-match "([a-z]|[0-9])" (string key-code)))
                                               ((current-global-keymap) prefix key-code))))
                 (with-suspended-rendering
                     (match binding
                       [(? procedure? thunk)  (clear-prefix!)
                                              (define now (current-milliseconds))
                                              (thunk)
                                              (define later (current-milliseconds))
                                              (status-line-time (- later now))
                                              (current-prefix-argument #f)]
                       [(list 'replace pre)   (set! prefix pre)]
                       ['prefix               (add-prefix! key)]
                       ['clear-prefix         (clear-prefix!)]
                       ['ignore               (void)]
                       ['exit                ; (save-buffer! (current-buffer))
                        ; TODO : Ask how to handle unsaved buffers
                        (send (frame-frame% f) on-exit)]
                       ['release             (void)]
                       [_                    (unless (equal? (send event get-key-code) 'release)
                                               (when (and (empty? prefix) key)
                                                 (message (~a "<" key "> undefined")))
                                               (clear-prefix!))])))
               (send this refresh-now)))))
        ;; Rendering
        (public on-paint-points)
        (define (display-status-line s)
          (unless (current-rendering-suspended?)
            (when (eq? (window-buffer this-window) (current-buffer))
              (send (frame-status-line f) set-label s))))
        (define (on-paint-points on?) ; render points only
          ; (log-info (~a (list 'on-paint-points count 'suspended? (current-rendering-suspended?))))
          ;(display (list count))
          (send-command
           (unless (current-rendering-suspended?)
             (parameterize ([current-render-points-only? #t]
                            ;[current-show-points?        on?]
                            )
               ; (display-status-line (status-line-hook))
               (define render (current-render-window))
               (unless (procedure? render)
                 (error 'huh))              
               (when (procedure? render)
                 (render (current-window)))))))
        (define/override (on-paint) ; render everything
          (send-command
           (unless (current-rendering-suspended?)
             (parameterize (#;[current-show-points? #t])
               (display-status-line (status-line-hook))
               (prepare-colors this-window)
               ((current-render-frame) f)))))
        (super-new)))
    (define canvas (new window-canvas% [parent panel] [style '(no-autoclear)]))
    (set-window-canvas! this-window canvas)
    (send canvas min-client-width  20)
    (send canvas min-client-height 20)
    ;;; blinking cursor / point
    ; start update-points thread
    (thread (λ () (let loop ([on? #t])
                    ; (log-info (~a (list 'thread count 'suspended? (current-rendering-suspended?))))
                    (set! on? #t)
                    (sleep/yield 0.2)
                    (unless #f #;(current-rendering-suspended?)
                      (send canvas on-paint-points on?))
                    (loop (not on?)))))
    canvas))

(define (maybe-recenter-top-bottom [force? #f] [w (current-window)])
  "Move line containing point to center of window."
  (define b                (window-buffer w))
  (define n                (number-of-lines-on-screen w))
  (define p                (buffer-point b))
  (unless (mark-buffer p)
    (error 'maybe-recenter-top-bottom "huh"))
  (define-values (row col) (mark-row+column p))  
  (define start-mark       (window-start-mark w))
  (define end-mark         (window-end-mark w))
  (define start-row        (mark-row start-mark))
  (define end-row          (mark-row end-mark))
  (when (or force?
            (not (and (<= start-row row) (< row (+ start-row n)))))
    (define n/2 (quotient n 2))
    (define new-start-row (max (- row n/2) 0))
    (define new-end-row   (+ new-start-row n))
    (mark-move-up! start-mark (- start-row new-start-row))
    (mark-move-up! end-mark   (-   end-row  new-end-row))
    (set! start-row new-start-row)
    (set! end-row   new-end-row))
  (values start-row end-row))
  



(define (window-switch-buffer! w b)
  ; switch to buffer
  (set-window-buffer! w b)
  ; make sure the window start and end marks are set correctly
  (maybe-recenter-top-bottom #t w))


;;;
;;; CACHED SCREEN LINE INFORMATION
;;;

; [See comment in "editor.rkt" on cached-screen-lines-ht]

; The cached information is a list.
; Each element of the list corresponds to a text line.
; Since a text line can be longer than a screen line, we need to know
; how the text line is split into screen lines.
;   (list start-pos-of-text-line
;         (list screen-line ...))
; A screen-line is represented like this:
;   (struct screen-line (line row screen-row start-position end-position contents)
; here line is the text line the screen line is part of.
; The row is the row of the text line in the text.
; The screen row is the screen row number.
; The contents field holds the actual strings and properties to be displayed.

(define (linearize-cached-screen-info info)
  (define (linearize1 line-info)
    (match line-info
      [(list pos (list sl* ...))
       (for/list ([s (in-list sl*)]
                  [i (in-naturals)])
         (list pos i s))]))
  (append* (map linearize1 info)))

(define (screen-line-length) (ref-buffer-local 'screen-line-length))

(define (screen-coordinates->text-coordinates
         start-row screen-row screen-column window [b (current-buffer)])
  ; start-row = row of first text line on screen
  (define info (hash-ref cached-screen-lines-ht b #f))
  (cond
    [(not info) (values #f #f)]
    [else       (define info* (linearize-cached-screen-info info))
                (define m (length info*))
                (cond
                  [(and (<= 0 screen-row) (< screen-row m))
                   (match (list-ref info* screen-row)
                     [(list pos i sl)  ; sl is the i'th screen line of the text line
                      (define row (screen-line-row sl))
                      ; the width of this this screen line is:
                      (define n   (- (screen-line-end-position sl) (screen-line-start-position sl)))
                      (define col (+ (* i (screen-line-length))
                                     (min n screen-column)))
                      (values row col)])]                  
                  [else
                   ; Turns out we have screen coordinates before or after anything cached.
                   ; This is typically due to a very short text being displayed.
                   ; Let's return the row and column of the end of the buffer.
                   (mark-row+column (window-end-mark window))])]))

