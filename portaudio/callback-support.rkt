#lang racket/base

(require ffi/vector
         ffi/unsafe
         (rename-in racket/contract [-> c->])
         "portaudio.rkt"
         "callbacks-lib.rkt"
         (only-in racket/match match-define))

;; this module provides an intermediate layer between 
;; the raw C primitives of portaudio and the higher-level
;; functions.  In particular, it's the one that "knows about"
;; the racket-specific C callback code, and provides functions
;; to interact with and manage those callbacks.

;; one of the tricky things is managing the resources that are shared
;; between C and Racket.

;; there are two sets of functions here; one for use in playing
;; a single sound from an existing buffer, and one for use in 
;; playing streaming audio. The nice thing about single sounds
;; is that they keep playing even through GC pauses. The bad thing
;; about single sounds is that you have to have them in memory 
;; before playing them, and you can't synchronize them accurately
;; (e.g., play one after the other so they sound seamless).

(provide
 (contract-out
  ;; make a sndplay record for playing a precomputed sound.
  [make-copying-info (c-> s16vector? nat? (or/c false? nat?) cpointer?)]
  ;; the raw pointer to the copying callback, for use with
  ;; a sndplay record:
  [copying-callback cpointer?]
  ;; the free function for a copying callback
  [copying-info-free cpointer?]
  ;; the free function callable from racket
  
  ;; make a sndplay record for recording a precomputed sound.
  [make-copying-info/rec (c-> nat? cpointer?)]
  ;; the raw pointer to the copying callback, for use with
  ;; a sndplay record:
  [copying-callback/rec cpointer?]
  ;; produce an s16vector from the given copying-info
  [extract-recorded-sound (c-> cpointer? s16vector?)]
  
  ;; make a streamplay record for playing a stream.
  [make-streaming-info (c-> integer? (list/c cpointer? cpointer?))]
  ;; is the stream all done?
  [all-done? (c-> cpointer? boolean?)]
  ;; call the given procedure with the buffers to be filled:
  [call-buffer-filler (c-> cpointer? procedure? any)]
  ;; the raw pointer to the streaming callback, for use with a
  ;; streamplay record:
  [streaming-callback cpointer?]
  ;; how many times has a given stream failed (i.e. not had a 
  ;; buffer provided in time by racket)?
  [stream-fails (c-> cpointer? integer?)]
  ;; the free function for a streaming callback
  [streaming-info-free cpointer?]))

(define (frames? n)
  (and (exact-integer? n)
       (<= 0 n)))

(define nat? exact-nonnegative-integer?)
(define false? not)

;; providing these for test cases only:
(provide stream-rec-buffer
         stream-rec-buffer-frames
         stream-rec-last-frame-read
         set-stream-rec-last-frame-written!
         set-stream-rec-last-offset-written!
         )

;; all of these functions assume 2-channel-interleaved 16-bit input:
(define channels 2)
(define sample-bytes (ctype-sizeof _sint16))

(define (frames->bytes f) (* channels (samples->bytes f)))
;; this should never be a non-integer. Typed racket would help here.
(define (bytes->frames b) (/ b (* channels sample-bytes)))
(define (samples->bytes f) (* sample-bytes f))

;; COPYING CALLBACK STRUCT ... we can use this for recording, too.
(define-cstruct _copying
  ([sound         _pointer]
   [cur-sample    _ulong]
   [num-samples   _ulong]))

;; create a fresh copying structure, including a full
;; malloc'ed copy of the sound data. No sanity checking of start
;; & stop is done.
(define (make-copying-info s16vec start-frame maybe-stop-frame)
  (define stop-frame (or maybe-stop-frame
                         (/ (s16vector-length s16vec) channels)))
  (define frames-to-copy (- stop-frame start-frame))
  ;; do this allocation first: it's much bigger, and more likely to fail:
  (define copied-sound (dll-malloc (frames->bytes frames-to-copy)))
  (define src-ptr (ptr-add (s16vector->cpointer s16vec)
                           (frames->bytes start-frame)))
  (memcpy copied-sound src-ptr (frames->bytes frames-to-copy))
  (define copying (cast (dll-malloc (ctype-sizeof _copying))
                             _pointer
                             _copying-pointer))
  (set-copying-sound! copying copied-sound)
  (set-copying-cur-sample! copying 0)
  (set-copying-num-samples! copying (* frames-to-copy channels))
  copying)

(define (make-copying-info/rec frames)
  ;; do this allocation first: it's much bigger, and more likely to fail:
  (define record-buffer (dll-malloc (frames->bytes frames)))
  (define copying (cast (dll-malloc (ctype-sizeof _copying))
                             _pointer
                             _copying-pointer))
  (set-copying-sound! copying record-buffer)
  (set-copying-cur-sample! copying 0)
  (set-copying-num-samples! copying (* frames channels))
  copying)

;; pull the recorded sound out of a copying structure.  This function
;; does not guarantee that the sound has been completely recorded yet.
(define (extract-recorded-sound copying)
  (define num-samples (copying-num-samples copying))
  (define s16vec (make-s16vector num-samples))
  (define dst-ptr (s16vector->cpointer s16vec))
  (memcpy dst-ptr (copying-sound copying) (samples->bytes num-samples))
  s16vec)

;; ... how to make sure that it doesn't get freed before it's copied out?




;; how many fails have occurred on the stream?
(define (stream-fails stream-rec)
  (stream-rec-fault-count stream-rec))

;; create a fresh streaming-sound-info structure, including
;; a ring buffer to be used in rendering the sound.
(define (make-streaming-info buffer-frames)
  ;; we must use the malloc defined in the dll here, to
  ;; keep windows happy.
  (define info (cast (dll-malloc (ctype-sizeof _stream-rec))
                     _pointer
                     _stream-rec-pointer))
  (set-stream-rec-buffer-frames! info buffer-frames)
  (set-stream-rec-buffer! info (dll-malloc (frames->bytes buffer-frames)))
  (set-stream-rec-last-frame-read! info 0)
  (set-stream-rec-last-offset-read! info 0)
  (set-stream-rec-last-frame-written! info 0)
  (set-stream-rec-last-offset-written! info 0)
  (set-stream-rec-fault-count! info 0)
  (define all-done-cell (malloc 'raw 4))
  (ptr-set! all-done-cell _uint32 0)
  (set-stream-rec-all-done! info all-done-cell)
  (list info all-done-cell))

;; given an all-done? cell, check whether it's nonzero.
;; be careful to call this with an all-done? cell, and not
;; just the stream-rec pointer that points to it, or you'll
;; get an immediate true.
(define (all-done? all-done-ptr)
  (not (= (ptr-ref all-done-ptr _uint32) 0)))

;; given a stream-rec and a buffer-filler, call the 
;; buffer filler twice: once to fill to the end of the buffer, and once 
;; to fill the beginning of the buffer up to the last-read point.
;; I'm ignoring the race conditions here; I believe the worst-case
;; is audible glitches, and we'll see how common they are.
(define (call-buffer-filler stream-info filler)
  (define buffer (stream-rec-buffer stream-info))
  (define buffer-frames (stream-rec-buffer-frames stream-info))
  (define buffer-bytes (frames->bytes buffer-frames))

  ;; the potential race condition here has no "major" bad effects, I believe:
  (define last-frame-read (stream-rec-last-frame-read stream-info))
  (define last-offset-read (stream-rec-last-offset-read stream-info))
  ;; safe to write ahead up to wraparound of last point read:
  (define last-frame-to-write (+ last-frame-read buffer-frames))
  (define last-offset-to-write last-offset-read)
  
  ;; start at last-written or last-read, whichever is later.
  (define last-frame-written (stream-rec-last-frame-written stream-info))
  (define last-offset-written (stream-rec-last-offset-written stream-info))
  (define underflow? (< last-frame-written last-frame-read))
  (define first-frame-to-write (cond [underflow? last-frame-read]
                                     [else       last-frame-written]))
  (define first-offset-to-write (cond [underflow? last-offset-read]
                                      [else       last-offset-written]))

  (unless (= first-frame-to-write last-frame-to-write)
    ;; do we have to wrap around?
    (cond [(<= last-offset-to-write first-offset-to-write)
           (define frames-to-end 
             (bytes->frames (- buffer-bytes first-offset-to-write)))
           (filler (ptr-add buffer first-offset-to-write)
                   frames-to-end)
           (filler buffer
                   (bytes->frames last-offset-to-write))]
          [else
           (filler (ptr-add buffer first-offset-to-write)
                   (- last-frame-to-write first-frame-to-write))])
    ;; update the stream-rec
    (set-stream-rec-last-frame-written! stream-info last-frame-to-write)
    (set-stream-rec-last-offset-written! stream-info last-offset-to-write)))


;; in order to get a raw pointer to pass back to C, we declare 
;; the function pointers as being simple structs:
(define-cstruct _bogus-struct
  ([datum _uint16]))

(define copying-callback
  (cast
   (get-ffi-obj "copyingCallback" callbacks-lib _bogus-struct)
   _bogus-struct-pointer
   _pa-stream-callback))

;; the callback for recording sounds (not working yet....)
(define copying-callback/rec
  (cast
   (get-ffi-obj "copyingCallbackRec" callbacks-lib _bogus-struct)
   _bogus-struct-pointer
   _pa-stream-callback))

(define streaming-callback
  (cast
   (get-ffi-obj "streamingCallback" callbacks-lib _bogus-struct)
   _bogus-struct-pointer
   _pa-stream-callback))

(define copying-info-free-fn
  (get-ffi-obj "freeCopyingInfo" callbacks-lib 
               (_fun _pointer -> _void)))

;; the copying-free function pointer as a cpointer
(define copying-info-free
  (cast
   (get-ffi-obj "freeCopyingInfo" callbacks-lib _bogus-struct)
   _bogus-struct-pointer
   _pa-stream-finished-callback))

(define streaming-info-free
  (cast
   (get-ffi-obj "freeStreamingInfo" callbacks-lib _bogus-struct)
   _bogus-struct-pointer
   _pa-stream-finished-callback))

(define dll-malloc
  (get-ffi-obj "dll_malloc" callbacks-lib (_fun _uint -> _pointer)))




(module+ test
  (require rackunit)
  
  (define (random-s16)
    (- (random #xffff) #x8000))

  (define copying-callback
    (get-ffi-obj "copyingCallback" callbacks-lib 
                 (_fun _pointer _pointer _ulong
                       _pointer _pa-stream-callback-flags
                       _copying-pointer
                       -> _int)))
  (define copying-callback-rec
    (get-ffi-obj "copyingCallbackRec" callbacks-lib 
                 (_fun _pointer _pointer _ulong
                       _pointer _pa-stream-callback-flags
                       _copying-pointer
                       -> _int)))
  
  (provide the-test-suite)
  (define the-test-suite
   (test-suite "copying callbacks"
               (let ()
                 
                 ;; create a bogus source vector with noise:
                 (define src-vec (make-s16vector 2048))
                 (for ([i (in-range 2048)])
                   (s16vector-set! src-vec i (random-s16)))
                 
                 (define offset-frame 436)
                 (define offset-sample (* 2 offset-frame))
                 (define remaining-samples (- 2048 offset-sample))
                 
                 ;; create a copying info, make sure it's correct:
                 (define copying (make-copying-info src-vec offset-frame #f))
                 (check-equal? (copying-cur-sample copying) 0)
                 (check-equal? (copying-num-samples copying) (- 2048 offset-sample))
                 (define copied-buf-ptr (copying-sound copying))
                 (for ([i (in-range remaining-samples)])
                   (check-equal? (s16vector-ref src-vec (+ i offset-sample))
                                 (ptr-ref copied-buf-ptr _sint16 i)))
                 
                 
                 ;; use the copying-callback to put it into another buffer.
                 
                 ;; target buffer:
                 (define dst-ptr (malloc _sint16 1024))
                 
                 
                 
                 (copying-callback #f dst-ptr 512 #f '() copying)
                 (for ([i (in-range 1024)])
                   (check-equal? (s16vector-ref src-vec (+ i offset-sample))
                                 (ptr-ref dst-ptr _sint16 i)))
                 (check-equal? (copying-cur-sample copying) 1024)
                 
                 (copying-callback #f dst-ptr 512 #f '() copying)
                 (for ([i (in-range (* 2 (- 512 offset-frame)))])
                   (check-equal? (s16vector-ref src-vec (+ i 1024 offset-sample))
                                 (ptr-ref dst-ptr _sint16 i)))
                 (for ([i (in-range offset-frame)])
                   (check-equal? (ptr-ref dst-ptr _sint16 (+ i (- 1024 (* 2 offset-frame))))
                                 0))
                 (check-equal? (copying-cur-sample copying) (- 2048 (* 2 offset-frame)))
                 )
               
               (let ()
                 ;; try again with recording callback:
                 
                 ;; create a bogus source vector with noise:
                 (define src-vec (make-s16vector 2048))
                 (for ([i (in-range 2048)])
                   (s16vector-set! src-vec i (random-s16)))
                 (check-equal? (ptr-ref (cast src-vec _s16vector _pointer) _sint16 17)
                               (s16vector-ref src-vec 17))
                 
                 (define offset-frame 436)
                 (define offset-sample (* 2 offset-frame))
                 (define remaining-samples (- 2048 offset-sample))
                 
                 ;; create a copying info, make sure it's correct:
                 (define copying (make-copying-info/rec (/ remaining-samples 2)))
                 (check-equal? (copying-cur-sample copying) 0)
                 (check-equal? (copying-num-samples copying) (- 2048 offset-sample))
                 
                 ;; use the copying-callback to put it into another buffer.
                 
                 
                 (copying-callback-rec (cast src-vec
                                             _s16vector
                                             _pointer)
                                       #f 512 #f '() copying)
                 (check-equal? (copying-cur-sample copying) 1024)
                 
                 (copying-callback-rec (ptr-add
                                        (cast src-vec
                                              _s16vector
                                              _pointer)
                                        2048)
                                       #f 512 #f '() copying)
                 (check-equal? (copying-cur-sample copying) (- 2048 offset-sample))
                 
                 (define dst-ptr (copying-sound copying))
                 (for ([i (in-range (* 2 (- 1024 offset-frame)))])
                   (check-equal? (s16vector-ref src-vec i)
                                 (ptr-ref dst-ptr _sint16 i)))
                 
                 (define result (extract-recorded-sound copying))
                 (for ([i (in-range (* 2 (- 1024 offset-frame)))])
                   (check-equal? (s16vector-ref src-vec i)
                                 (s16vector-ref result i)))
                 
                 )))
  
  )