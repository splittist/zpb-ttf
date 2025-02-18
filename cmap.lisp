;;; Copyright (c) 2006 Zachary Beane, All Rights Reserved
;;;
;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;;;
;;; Loading data from the "cmap" table.
;;;
;;;  https://docs.microsoft.com/en-us/typography/opentype/spec/cmap
;;;  http://developer.apple.com/fonts/TTRefMan/RM06/Chap6cmap.html
;;;
;;; $Id: cmap.lisp,v 1.15 2006/03/23 22:23:32 xach Exp $

(in-package #:zpb-ttf)

(deftype cmap-value-table ()
  `(array (unsigned-byte 16) (*)))

;;; FIXME: "unicode-cmap" is actually a format 4 character map that
;;; happens to currently be loaded from a Unicode-compatible
;;; subtable. However, other character maps (like Microsoft's Symbol
;;; encoding) also use format 4 and could be loaded with these
;;; "unicode" objects and functions.

(defclass unicode-cmap ()
  ((segment-count :initarg :segment-count :reader segment-count)
   (end-codes :initarg :end-codes :reader end-codes)
   (start-codes :initarg :start-codes :reader start-codes)
   (id-deltas :initarg :id-deltas :reader id-deltas)
   (id-range-offsets :initarg :id-range-offsets :reader id-range-offsets)
   (glyph-indexes :initarg :glyph-indexes :accessor glyph-indexes)))

(defclass format-12-cmap ()
  ((group-count :initarg :group-count :reader group-count)
   (start-codes :initarg :start-codes :reader start-codes)
   (end-codes :initarg :end-codes :reader end-codes)
   (glyph-starts :initarg :glyph-starts :accessor glyph-starts)))

(defun load-unicode-cmap-format12 (stream)
  "Load a Unicode character map of type 12 from STREAM starting at the
current offset. Assumes format is already read and checked."
  (let* ((reserved (read-uint16 stream))
         (subtable-length (read-uint32 stream))
         (language-code (read-uint32 stream))
         (group-count (read-uint32 stream))
         (start-codes (make-array group-count
                                  :element-type '(unsigned-byte 32)
                                  :initial-element 0))
         (end-codes (make-array group-count
                                :element-type '(unsigned-byte 32)
                                :initial-element 0))
         (glyph-starts (make-array group-count
                                   :element-type '(unsigned-byte 32)
                                   :initial-element 0)))
    (declare (ignore reserved language-code subtable-length))
    (loop for i below group-count
          do (setf (aref start-codes i) (read-uint32 stream)
                   (aref end-codes i) (read-uint32 stream)
                   (aref glyph-starts i) (read-uint32 stream)))
    (make-instance 'format-12-cmap
                   :group-count group-count
                   :start-codes start-codes
                   :end-codes end-codes
                   :glyph-starts glyph-starts)))

(defun load-unicode-cmap (stream)
  "Load a Unicode character map of type 4 or 12 from STREAM starting at
the current offset."
  (let ((format (read-uint16 stream)))
    (when (= format 12)
      (return-from load-unicode-cmap (load-unicode-cmap-format12 stream)))
    (when (/= format 4)
      (error 'unsupported-format
             :location "\"cmap\" subtable"
             :actual-value format
             :expected-values (list 4))))
  (let ((table-start (- (file-position stream) 2))
        (subtable-length (read-uint16 stream))
        (language-code (read-uint16 stream))
        (segment-count (/ (read-uint16 stream) 2))
        (search-range (read-uint16 stream))
        (entry-selector (read-uint16 stream))
        (range-shift (read-uint16 stream)))
    (declare (ignore language-code search-range entry-selector range-shift))
    (flet ((make-and-load-array (&optional (size segment-count))
             (loop with array = (make-array size
                                            :element-type '(unsigned-byte 16)
                                            :initial-element 0)
                   for i below size
                   do (setf (aref array i) (read-uint16 stream))
                   finally (return array)))
           (make-signed (i)
             (if (logbitp 15 i)
                 (1- (- (logandc2 #xFFFF i)))
                 i)))
      (let ((end-codes (make-and-load-array))
            (pad (read-uint16 stream))
            (start-codes (make-and-load-array))
            (id-deltas (make-and-load-array))
            (id-range-offsets (make-and-load-array))
            (glyph-index-array-size (/ (- subtable-length
                                          (- (file-position stream)
                                             table-start))
                                       2)))
        (declare (ignore pad))
        (make-instance 'unicode-cmap
                       :segment-count segment-count
                       :end-codes end-codes
                       :start-codes start-codes
                       ;; these are really signed, so sign them
                       :id-deltas (map 'vector #'make-signed id-deltas)
                       :id-range-offsets id-range-offsets
                       :glyph-indexes (make-and-load-array glyph-index-array-size))))))


(defun %decode-format-4-cmap-code-point-index (code-point cmap index)
  "Return the index of the Unicode CODE-POINT in a format 4 CMAP, if
present, otherwise NIL. Assumes INDEX points to the element of the
CMAP arrays (END-CODES etc) corresponding to code-point."
  (with-slots (end-codes start-codes
               id-deltas id-range-offsets
               glyph-indexes)
      cmap
    (declare (type cmap-value-table
                   end-codes start-codes
                   id-range-offsets
                   glyph-indexes))
    (let ((start-code (aref start-codes index))
          (end-code (aref end-codes index))
          (id-range-offset (aref id-range-offsets index))
          (id-delta (aref id-deltas index)))
      (cond
        ((< code-point start-code)
         0)
        ;; ignore empty final segment
        ((and (= 65535 start-code end-code))
         0)
        ((zerop id-range-offset)
         (logand #xFFFF (+ code-point id-delta)))
        (t
         (let* ((glyph-index-offset (- (+ index
                                          (ash id-range-offset -1)
                                          (- code-point start-code))
                                       (segment-count cmap)))
                (glyph-index (aref (glyph-indexes cmap)
                                   glyph-index-offset)))
           (logand #xFFFF
                   (+ glyph-index id-delta))))))))

(defun %decode-format-12-cmap-code-point-index (code-point cmap index)
  "Return the index of the Unicode CODE-POINT in a format 12 CMAP, if
present, otherwise NIL. Assumes INDEX points to the element of the
CMAP arrays (END-CODES etc) corresponding to code-point."
  (with-slots (end-codes start-codes glyph-starts)
      cmap
    (declare (type (simple-array (unsigned-byte 32))
                   end-codes start-codes glyph-starts))
    (let ((start-code (aref start-codes index))
          (start-glyph-id (aref glyph-starts index)))
      (if (< code-point start-code)
          0
          (+ start-glyph-id (- code-point start-code))))))

(defgeneric code-point-font-index-from-cmap (code-point cmap)
  (:documentation "Return the index of the Unicode CODE-POINT in
CMAP, if present, otherwise NIL.")
  (:method (code-point (cmap unicode-cmap))
    (with-slots (end-codes)
        cmap
      (declare (type cmap-value-table end-codes))
      (dotimes (i (segment-count cmap) 1)
        (when (<= code-point (aref end-codes i))
          (return (%decode-format-4-cmap-code-point-index code-point cmap i))))))
  (:method (code-point (cmap format-12-cmap))
    (with-slots (end-codes)
        cmap
      (declare (type (simple-array (unsigned-byte 32)) end-codes))
      (dotimes (i (group-count cmap) 1)
        (when (<= code-point (aref end-codes i))
          (return
            (%decode-format-12-cmap-code-point-index code-point cmap i)))))))

(defmethod invert-character-map (font-loader)
  "Return a vector mapping font indexes to code points."
  (with-slots (start-codes end-codes)
      (character-map font-loader)
    (let ((points (make-array (glyph-count font-loader) :initial-element -1))
          (cmap (character-map font-loader)))
      (dotimes (i (length end-codes) points)
        (loop for j from (aref start-codes i) to (aref end-codes i)
              for font-index
                = (typecase cmap
                    (unicode-cmap
                     (%decode-format-4-cmap-code-point-index j cmap i))
                    (format-12-cmap
                     (%decode-format-12-cmap-code-point-index j cmap i))
                    (t
                     (code-point-font-index-from-cmap j cmap)))
              when (minusp (svref points font-index))
                do (setf (svref points font-index) j))))))


(defgeneric code-point-font-index (code-point font-loader)
  (:documentation "Return the index of the Unicode CODE-POINT in
FONT-LOADER, if present, otherwise NIL.")
  (:method (code-point font-loader)
    (code-point-font-index-from-cmap code-point (character-map font-loader))))

(defgeneric font-index-code-point (glyph-index font-loader)
  (:documentation "Return the code-point for a given glyph index.")
  (:method (glyph-index font-loader)
    (let ((point (aref (inverse-character-map font-loader) glyph-index)))
      (if (plusp point)
          point
          0))))

(defun %load-cmap-info (font-loader platform specific)
  (seek-to-table "cmap" font-loader)
  (with-slots (input-stream)
      font-loader
    (let ((start-pos (file-position input-stream))
          (version-number (read-uint16 input-stream))
          (subtable-count (read-uint16 input-stream))
          (foundp nil))
      (declare (ignore version-number))
      (loop repeat subtable-count
            for platform-id = (read-uint16 input-stream)
            for platform-specific-id = (read-uint16 input-stream)
            for offset = (+ start-pos (read-uint32 input-stream))
            when (and (= platform-id platform)
                      (or (eql platform-specific-id specific)
                          (and (consp specific)
                               (member platform-specific-id specific))))
            do
            (file-position input-stream offset)
            (setf (character-map font-loader) (load-unicode-cmap input-stream))
            (setf (inverse-character-map font-loader)
                  (invert-character-map font-loader)
                  foundp t)
            (return))
      foundp)))

(defun %unknown-cmap-error (font-loader)
  (seek-to-table "cmap" font-loader)
  (with-slots (input-stream)
      font-loader
    (let ((start-pos (file-position input-stream))
          (version-number (read-uint16 input-stream))
          (subtable-count (read-uint16 input-stream))
          (cmaps nil))
      (declare (ignore version-number))
      (loop repeat subtable-count
            for platform-id = (read-uint16 input-stream)
            for platform-specific-id = (read-uint16 input-stream)
            for offset = (+ start-pos (read-uint32 input-stream))
            for pos = (file-position input-stream)
            do (file-position input-stream offset)
               (push (list (platform-id-name platform-id)
                           (encoding-id-name platform-id platform-specific-id)
                           :type (read-uint16 input-stream))
                     cmaps)
               (file-position input-stream pos))
      (error "Could not find supported character map in font file~% available cmap tables = ~s"
             cmaps))))


(defclass format-0-cmap ()
  ((glyph-index-array :initform (make-array 256 :element-type '(unsigned-byte 8))
		      :reader glyph-index-array)))

(defun %load-cmap-format-0 (font-loader)
  "Load a single-byte character map of type 0 from STREAM starting at the
current offset."
  (seek-to-table "cmap" font-loader)
  (with-slots (input-stream)
      font-loader
    (let ((start-pos (file-position input-stream))
	  (version-number (read-uint16 input-stream))
	  (subtable-count (read-uint16 input-stream))
	  (foundp nil))
      (declare (ignore version-number))
      (loop repeat subtable-count
	    for platform-id = (read-uint16 input-stream)
	    for platform-specific-id = (read-uint16 input-stream)
	    for offset = (+ start-pos (read-uint32 input-stream))
	    when (and (= platform-id +macintosh-platform-id+)
		      (= platform-specific-id 0)) ; 1 or 0?
	      do (file-position input-stream offset)
		 (let ((format (read-uint16 input-stream))
		       (length (read-uint16 input-stream))
		       (language (read-uint16 input-stream)))
		   (declare (ignore language))
		   (assert (and (= 0 format) (= 262 length)))
		   (let ((cmap (make-instance 'format-0-cmap)))
		     (read-sequence (glyph-index-array cmap) input-stream)
		     (setf (character-map font-loader) cmap
			   (inverse-character-map font-loader) (invert-format-0-cmap cmap)
			   foundp t)
		     (return))))
      foundp)))
		   
(defmethod code-point-font-index-from-cmap (code-point (cmap format-0-cmap))
  (position code-point (glyph-index-array cmap)))

(defun invert-format-0-cmap (cmap)
  (let ((inverse (make-array 256 :element-type '(unsigned-byte 8))))
    (loop for code-point across (glyph-index-array cmap)
	  for index from 0
	  do (setf (aref inverse code-point) index))
    inverse))

(defmethod load-cmap-info ((font-loader font-loader))
  (or (%load-cmap-info font-loader +unicode-platform-id+
                       +unicode-2.0-full-encoding-id+) ;; full unicode
      (%load-cmap-info font-loader +microsoft-platform-id+
                       +microsoft-unicode-ucs4-encoding-id+) ;; full unicode
      (%load-cmap-info font-loader +microsoft-platform-id+
                       +microsoft-unicode-bmp-encoding-id+) ;; bmp
      (%load-cmap-info font-loader +unicode-platform-id+
                       +unicode-2.0-encoding-id+) ;; bmp
      (%load-cmap-info font-loader +unicode-platform-id+
                       '(0 1 2 3 4)) ;; all except variation and last-resort
      (%load-cmap-info font-loader +microsoft-platform-id+
                       +microsoft-symbol-encoding-id+) ;; ms symbol
      (%load-cmap-format-0 font-loader) ;; ADDED BY JQS
      (%unknown-cmap-error font-loader)))

(defun available-character-maps (loader)
  (seek-to-table "cmap" loader)
  (let ((stream (input-stream loader)))
    (let ((start-pos (file-position stream))
          (version-number (read-uint16 stream))
          (subtable-count (read-uint16 stream)))
      (declare (ignore start-pos))
      (assert (zerop version-number))
      (dotimes (i subtable-count)
        (let ((platform-id (read-uint16 stream))
              (encoding-id (read-uint16 stream))
              (offset (read-uint32 stream)))
          (declare (ignore offset))
          (format t "~D (~A) - ~D (~A)~%"
                  platform-id (platform-id-name platform-id)
                  encoding-id (encoding-id-name platform-id encoding-id)))))))

