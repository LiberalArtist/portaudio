#lang racket

;; Heavily based on Sam Tobin-Hochstadt's bcrypt/private/install.rkt
;; https://github.com/samth/bcrypt.rkt

(require dynext/file
         dynext/link
         racket/file
         racket/runtime-path)

(define-runtime-path callbacks.c
  "callbacks.c")

(define so-path
  (let-values ([{base _name _dir} (split-path callbacks.c)])
    (build-path base
                (system-library-subpath #f)
                (append-extension-suffix "callbacks"))))

(define (cc)
  (parameterize ([current-use-mzdyn #f])
    (when (file-exists? so-path)
      (delete-file so-path))
    (make-parent-directory* so-path)
    (link-extension #f ;; not quiet
                    (list callbacks.c)
                    so-path)))
