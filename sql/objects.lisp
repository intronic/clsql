;;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; *************************************************************************
;;;;
;;;; $Id$
;;;;
;;;; The CLSQL Object Oriented Data Definitional Language (OODDL)
;;;; and Object Oriented Data Manipulation Language (OODML).
;;;;
;;;; This file is part of CLSQL.
;;;;
;;;; CLSQL users are granted the rights to distribute and use this software
;;;; as governed by the terms of the Lisp Lesser GNU Public License
;;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;; *************************************************************************

(in-package #:clsql-sys)

(defclass standard-db-object ()
  ((view-database :initform nil :initarg :view-database :reader view-database
    :db-kind :virtual))
  (:metaclass standard-db-class)
  (:documentation "Superclass for all CLSQL View Classes."))

(defvar *db-auto-sync* nil 
  "A non-nil value means that creating View Class instances or
  setting their slots automatically creates/updates the
  corresponding records in the underlying database.")

(defvar *db-deserializing* nil)
(defvar *db-initializing* nil)

(defmethod slot-value-using-class ((class standard-db-class) instance slot-def)
  (declare (optimize (speed 3)))
  (unless *db-deserializing*
    (let* ((slot-name (%svuc-slot-name slot-def))
	   (slot-object (%svuc-slot-object slot-def class))
	   (slot-kind (view-class-slot-db-kind slot-object)))
      (when (and (eql slot-kind :join)
                 (not (slot-boundp instance slot-name)))
        (let ((*db-deserializing* t))
          (if (view-database instance)
              (setf (slot-value instance slot-name)
                    (fault-join-slot class instance slot-object))
              (setf (slot-value instance slot-name) nil))))))
  (call-next-method))

(defmethod (setf slot-value-using-class) (new-value (class standard-db-class)
					  instance slot-def)
  (declare (ignore new-value))
  (let* ((slot-name (%svuc-slot-name slot-def))
	 (slot-object (%svuc-slot-object slot-def class))
	 (slot-kind (view-class-slot-db-kind slot-object)))
    (call-next-method)
    (when (and *db-auto-sync* 
	       (not *db-initializing*)
	       (not *db-deserializing*)
	       (not (eql slot-kind :virtual)))
      (update-record-from-slot instance slot-name))))

(defmethod initialize-instance ((object standard-db-object)
					&rest all-keys &key &allow-other-keys)
  (declare (ignore all-keys))
  (let ((*db-initializing* t))
    (call-next-method)
    (when (and *db-auto-sync*
	       (not *db-deserializing*))
      (update-records-from-instance object))))

;;
;; Build the database tables required to store the given view class
;;

(defun create-view-from-class (view-class-name
                               &key (database *default-database*))
  "Creates a table as defined by the View Class VIEW-CLASS-NAME
in DATABASE which defaults to *DEFAULT-DATABASE*."
  (let ((tclass (find-class view-class-name)))
    (if tclass
        (let ((*default-database* database))
          (%install-class tclass database))
        (error "Class ~s not found." view-class-name)))
  (values))

(defmethod %install-class ((self standard-db-class) database &aux schemadef)
  (dolist (slotdef (ordered-class-slots self))
    (let ((res (database-generate-column-definition (class-name self)
                                                    slotdef database)))
      (when res 
        (push res schemadef))))
  (unless schemadef
    (error "Class ~s has no :base slots" self))
  (create-table (sql-expression :table (view-table self)) schemadef
                :database database
                :constraints (database-pkey-constraint self database))
  (push self (database-view-classes database))
  t)

(defmethod database-pkey-constraint ((class standard-db-class) database)
  (let ((keylist (mapcar #'view-class-slot-column (keyslots-for-class class))))
    (when keylist 
      (convert-to-db-default-case
       (format nil "CONSTRAINT ~APK PRIMARY KEY~A"
	       (database-output-sql (view-table class) database)
	       (database-output-sql keylist database))
       database))))

(defmethod database-generate-column-definition (class slotdef database)
  (declare (ignore database class))
  (when (member (view-class-slot-db-kind slotdef) '(:base :key))
    (let ((cdef
           (list (sql-expression :attribute (view-class-slot-column slotdef))
                 (specified-type slotdef))))
      (setf cdef (append cdef (list (view-class-slot-db-type slotdef))))
      (let ((const (view-class-slot-db-constraints slotdef)))
        (when const 
          (setq cdef (append cdef (list const)))))
      cdef)))


;;
;; Drop the tables which store the given view class
;;

(defun drop-view-from-class (view-class-name &key (database *default-database*))
  "Removes a table defined by the View Class VIEW-CLASS-NAME from
DATABASE which defaults to *DEFAULT-DATABASE*."
  (let ((tclass (find-class view-class-name)))
    (if tclass
        (let ((*default-database* database))
          (%uninstall-class tclass))
        (error "Class ~s not found." view-class-name)))
  (values))

(defun %uninstall-class (self &key (database *default-database*))
  (drop-table (sql-expression :table (view-table self))
              :if-does-not-exist :ignore
              :database database)
  (setf (database-view-classes database)
        (remove self (database-view-classes database))))


;;
;; List all known view classes
;;

(defun list-classes (&key (test #'identity)
		     (root-class (find-class 'standard-db-object))
		     (database *default-database*))
  "Returns a list of all the View Classes which are connected to
DATABASE, which defaults to *DEFAULT-DATABASE*, and which descend
from the class ROOT-CLASS and which satisfy the function TEST. By
default ROOT-CLASS is STANDARD-DB-OBJECT and TEST is IDENTITY."
  (flet ((find-superclass (class) 
	   (member root-class (class-precedence-list class))))
    (let ((view-classes (and database (database-view-classes database))))
      (when view-classes
	(remove-if #'(lambda (c) (or (not (funcall test c))
				     (not (find-superclass c))))
		   view-classes)))))

;;
;; Define a new view class
;;

(defmacro def-view-class (class supers slots &rest cl-options)
  "Creates a View Class called CLASS whose slots SLOTS can map
onto the attributes of a table in a database. If SUPERS is nil
then the superclass of CLASS will be STANDARD-DB-OBJECT,
otherwise SUPERS is a list of superclasses for CLASS which must
include STANDARD-DB-OBJECT or a descendent of this class. The
syntax of DEFCLASS is extended through the addition of a class
option :base-table which defines the database table onto which
the View Class maps and which defaults to CLASS. The DEFCLASS
syntax is also extended through additional slot
options. The :db-kind slot option specifies the kind of DB
mapping which is performed for this slot and defaults to :base
which indicates that the slot maps to an ordinary column of the
database table. A :db-kind value of :key indicates that this slot
is a special kind of :base slot which maps onto a column which is
one of the unique keys for the database table, the value :join
indicates this slot represents a join onto another View Class
which contains View Class objects, and the value :virtual
indicates a standard CLOS slot which does not map onto columns of
the database table. If a slot is specified with :db-kind :join,
the slot option :db-info contains a list which specifies the
nature of the join. For slots of :db-kind :base or :key,
the :type slot option has a special interpretation such that Lisp
types, such as string, integer and float are automatically
converted into appropriate SQL types for the column onto which
the slot maps. This behaviour may be over-ridden using
the :db-type slot option which is a string specifying the
vendor-specific database type for this slot's column definition
in the database. The :column slot option specifies the name of
the SQL column which the slot maps onto, if :db-kind is
not :virtual, and defaults to the slot name. The :void-value slot
option specifies the value to store if the SQL value is NULL and
defaults to NIL. The :db-constraints slot option is a string
representing an SQL table constraint expression or a list of such
strings."
  `(progn
    (defclass ,class ,supers ,slots 
      ,@(if (find :metaclass `,cl-options :key #'car)
	    `,cl-options
	    (cons '(:metaclass clsql-sys::standard-db-class) `,cl-options)))
    (finalize-inheritance (find-class ',class))
    (find-class ',class)))

(defun keyslots-for-class (class)
  (slot-value class 'key-slots))

(defun key-qualifier-for-instance (obj &key (database *default-database*))
  (let ((tb (view-table (class-of obj))))
    (flet ((qfk (k)
             (sql-operation '==
                            (sql-expression :attribute
                                            (view-class-slot-column k)
                                            :table tb)
                            (db-value-from-slot
                             k
                             (slot-value obj (slot-definition-name k))
                             database))))
      (let* ((keys (keyslots-for-class (class-of obj)))
	     (keyxprs (mapcar #'qfk (reverse keys))))
	(cond
          ((= (length keyxprs) 0) nil)
          ((= (length keyxprs) 1) (car keyxprs))
          ((> (length keyxprs) 1) (apply #'sql-operation 'and keyxprs)))))))

;;
;; Function used by 'generate-selection-list'
;;

(defun generate-attribute-reference (vclass slotdef)
  (cond
   ((eq (view-class-slot-db-kind slotdef) :base)
    (sql-expression :attribute (view-class-slot-column slotdef)
		    :table (view-table vclass)))
   ((eq (view-class-slot-db-kind slotdef) :key)
    (sql-expression :attribute (view-class-slot-column slotdef)
		    :table (view-table vclass)))
   (t nil)))

;;
;; Function used by 'find-all'
;;

(defun generate-selection-list (vclass)
  (let ((sels nil))
    (dolist (slotdef (ordered-class-slots vclass))
      (let ((res (generate-attribute-reference vclass slotdef)))
	(when res
          (push (cons slotdef res) sels))))
    (if sels
	sels
        (error "No slots of type :base in view-class ~A" (class-name vclass)))))



(defun generate-retrieval-joins-list (vclass retrieval-method)
  "Returns list of immediate join slots for a class."
  (let ((join-slotdefs nil))
    (dolist (slotdef (ordered-class-slots vclass) join-slotdefs)
      (when (and (eq :join (view-class-slot-db-kind slotdef))
		 (eq retrieval-method (gethash :retrieval (view-class-slot-db-info slotdef))))
	(push slotdef join-slotdefs)))))

(defun generate-immediate-joins-selection-list (vclass)
  "Returns list of immediate join slots for a class."
  (let (sels)
    (dolist (joined-slot (generate-retrieval-joins-list vclass :immediate) sels)
      (let* ((join-class-name (gethash :join-class (view-class-slot-db-info joined-slot)))
	     (join-class (when join-class-name (find-class join-class-name))))
	(dolist (slotdef (ordered-class-slots join-class))
	  (let ((res (generate-attribute-reference join-class slotdef)))
	    (when res
	      (push (cons slotdef res) sels))))))
    sels))


;; Called by 'get-slot-values-from-view'
;;

(defvar *update-context* nil)

(defmethod update-slot-from-db ((instance standard-db-object) slotdef value)
  (declare (optimize (speed 3) #+cmu (extensions:inhibit-warnings 3)))
  (let* ((slot-reader (view-class-slot-db-reader slotdef))
	 (slot-name   (slot-definition-name slotdef))
	 (slot-type   (specified-type slotdef))
	 (*update-context* (cons (type-of instance) slot-name)))
    (cond ((and value (null slot-reader))
           (setf (slot-value instance slot-name)
                 (read-sql-value value (delistify slot-type)
                                 (view-database instance)
				 (database-underlying-type
				  (view-database instance)))))
	  ((null value)
           (update-slot-with-null instance slot-name slotdef))
          ((typep slot-reader 'string)
           (setf (slot-value instance slot-name)
                 (format nil slot-reader value)))
          ((typep slot-reader 'function)
           (setf (slot-value instance slot-name)
                 (apply slot-reader (list value))))
          (t
           (error "Slot reader is of an unusual type.")))))

(defmethod key-value-from-db (slotdef value database) 
  (declare (optimize (speed 3) #+cmu (extensions:inhibit-warnings 3)))
  (let ((slot-reader (view-class-slot-db-reader slotdef))
        (slot-type (specified-type slotdef)))
    (cond ((and value (null slot-reader))
           (read-sql-value value (delistify slot-type) database
			   (database-underlying-type database)))
          ((null value)
           nil)
          ((typep slot-reader 'string)
           (format nil slot-reader value))
          ((typep slot-reader 'function)
           (apply slot-reader (list value)))
          (t
           (error "Slot reader is of an unusual type.")))))

(defun db-value-from-slot (slotdef val database)
  (let ((dbwriter (view-class-slot-db-writer slotdef))
	(dbtype (specified-type slotdef)))
    (typecase dbwriter
      (string (format nil dbwriter val))
      (function (apply dbwriter (list val)))
      (t
       (database-output-sql-as-type
	(typecase dbtype
	  (cons (car dbtype))
	  (t dbtype))
	val database (database-underlying-type database))))))

(defun check-slot-type (slotdef val)
  (let* ((slot-type (specified-type slotdef))
         (basetype (if (listp slot-type) (car slot-type) slot-type)))
    (when (and slot-type val)
      (unless (typep val basetype)
        (error 'sql-user-error
	       :message
	       (format nil "Invalid value ~A in slot ~A, not of type ~A."
		       val (slot-definition-name slotdef) slot-type))))))

;;
;; Called by find-all
;;

(defmethod get-slot-values-from-view (obj slotdeflist values)
    (flet ((update-slot (slot-def values)
	     (update-slot-from-db obj slot-def values)))
      (mapc #'update-slot slotdeflist values)
      obj))

(defmethod update-record-from-slot ((obj standard-db-object) slot &key
				    (database *default-database*))
  (let* ((database (or (view-database obj) database))
	 (vct (view-table (class-of obj)))
         (sd (slotdef-for-slot-with-class slot (class-of obj))))
    (check-slot-type sd (slot-value obj slot))
    (let* ((att (view-class-slot-column sd))
           (val (db-value-from-slot sd (slot-value obj slot) database)))
      (cond ((and vct sd (view-database obj))
             (update-records (sql-expression :table vct)
                             :attributes (list (sql-expression :attribute att))
                             :values (list val)
                             :where (key-qualifier-for-instance
                                     obj :database database)
                             :database database))
            ((and vct sd (not (view-database obj)))
	     (insert-records :into (sql-expression :table vct)
                             :attributes (list (sql-expression :attribute att))
                             :values (list val)
			     :database database)
	     (setf (slot-value obj 'view-database) database))
            (t
             (error "Unable to update record.")))))
  (values))

(defmethod update-record-from-slots ((obj standard-db-object) slots &key
                                     (database *default-database*))
  (let* ((database (or (view-database obj) database))
	 (vct (view-table (class-of obj)))
         (sds (slotdefs-for-slots-with-class slots (class-of obj)))
         (avps (mapcar #'(lambda (s)
                           (let ((val (slot-value
                                       obj (slot-definition-name s))))
                             (check-slot-type s val)
                             (list (sql-expression
                                    :attribute (view-class-slot-column s))
                                   (db-value-from-slot s val database))))
                       sds)))
    (cond ((and avps (view-database obj))
           (update-records (sql-expression :table vct)
                           :av-pairs avps
                           :where (key-qualifier-for-instance
                                   obj :database database)
                           :database database))
          ((and avps (not (view-database obj)))
           (insert-records :into (sql-expression :table vct)
                           :av-pairs avps
                           :database database)
           (setf (slot-value obj 'view-database) database))
          (t
           (error "Unable to update records"))))
  (values))

(defmethod update-records-from-instance ((obj standard-db-object)
                                         &key (database *default-database*))
  (let ((database (or (view-database obj) database)))
    (labels ((slot-storedp (slot)
	       (and (member (view-class-slot-db-kind slot) '(:base :key))
		    (slot-boundp obj (slot-definition-name slot))))
	     (slot-value-list (slot)
	       (let ((value (slot-value obj (slot-definition-name slot))))
		 (check-slot-type slot value)
		 (list (sql-expression :attribute (view-class-slot-column slot))
		       (db-value-from-slot slot value database)))))
      (let* ((view-class (class-of obj))
	     (view-class-table (view-table view-class))
	     (slots (remove-if-not #'slot-storedp 
				   (ordered-class-slots view-class)))
	     (record-values (mapcar #'slot-value-list slots)))
	(unless record-values
	  (error "No settable slots."))
	(if (view-database obj)
	    (update-records (sql-expression :table view-class-table)
			    :av-pairs record-values
			    :where (key-qualifier-for-instance
				    obj :database database)
			    :database database)
	    (progn
	      (insert-records :into (sql-expression :table view-class-table)
			      :av-pairs record-values
			      :database database)
	      (setf (slot-value obj 'view-database) database))))))
  (values))

(defmethod delete-instance-records ((instance standard-db-object))
  (let ((vt (sql-expression :table (view-table (class-of instance))))
	(vd (view-database instance)))
    (if vd
	(let ((qualifier (key-qualifier-for-instance instance :database vd)))
	  (delete-records :from vt :where qualifier :database vd)
	  (setf (slot-value instance 'view-database) nil))
	(signal-no-database-error vd))))

(defmethod update-instance-from-records ((instance standard-db-object)
                                         &key (database *default-database*))
  (let* ((view-class (find-class (class-name (class-of instance))))
         (view-table (sql-expression :table (view-table view-class)))
         (vd (or (view-database instance) database))
         (view-qual (key-qualifier-for-instance instance :database vd))
         (sels (generate-selection-list view-class))
         (res (apply #'select (append (mapcar #'cdr sels)
                                      (list :from  view-table
                                            :where view-qual)
				      (list :result-types nil)))))
    (when res
      (get-slot-values-from-view instance (mapcar #'car sels) (car res)))))

(defmethod update-slot-from-record ((instance standard-db-object)
                                    slot &key (database *default-database*))
  (let* ((view-class (find-class (class-name (class-of instance))))
         (view-table (sql-expression :table (view-table view-class)))
         (vd (or (view-database instance) database))
         (view-qual (key-qualifier-for-instance instance :database vd))
         (slot-def (slotdef-for-slot-with-class slot view-class))
         (att-ref (generate-attribute-reference view-class slot-def))
         (res (select att-ref :from  view-table :where view-qual
		      :result-types nil)))
    (when res 
      (get-slot-values-from-view instance (list slot-def) (car res)))))


(defmethod update-slot-with-null ((object standard-db-object)
				  slotname
				  slotdef)
  (setf (slot-value object slotname) (slot-value slotdef 'void-value)))

(defvar +no-slot-value+ '+no-slot-value+)

(defsql sql-slot-value (:symbol "slot-value") (classname slot &optional (value +no-slot-value+) (database *default-database*))
  (let* ((class (find-class classname))
	 (sld (slotdef-for-slot-with-class slot class)))
    (if sld
	(if (eq value +no-slot-value+)
	    (sql-expression :attribute (view-class-slot-column sld)
			    :table (view-table class))
            (db-value-from-slot
             sld
             value
             database))
        (error "Unknown slot ~A for class ~A" slot classname))))

(defsql sql-view-class (:symbol "view-class") (classname &optional (database *default-database*))
	(declare (ignore database))
	(let* ((class (find-class classname)))
	  (unless (view-table class)
	    (error "No view-table for class ~A"  classname))
	  (sql-expression :table (view-table class))))

(defmethod database-get-type-specifier (type args database db-type)
  (declare (ignore type args database db-type))
  "VARCHAR(255)")

(defmethod database-get-type-specifier ((type (eql 'integer)) args database db-type)
  (declare (ignore database db-type))
  (if args
      (format nil "INT(~A)" (car args))
      "INT"))

(deftype bigint () 
  "An integer larger than a 32-bit integer, this width may vary by SQL implementation."
  'integer)

(defmethod database-get-type-specifier ((type (eql 'bigint)) args database db-type)
  (declare (ignore args database db-type))
  "BIGINT")
              
(defmethod database-get-type-specifier ((type (eql 'simple-base-string)) args
                                        database db-type)
  (declare (ignore database db-type))
  (if args
      (format nil "VARCHAR(~A)" (car args))
      "VARCHAR(255)"))

(defmethod database-get-type-specifier ((type (eql 'simple-string)) args
                                        database db-type)
  (declare (ignore database db-type))
  (if args
      (format nil "VARCHAR(~A)" (car args))
      "VARCHAR(255)"))

(defmethod database-get-type-specifier ((type (eql 'string)) args database db-type)
  (declare (ignore database db-type))
  (if args
      (format nil "VARCHAR(~A)" (car args))
      "VARCHAR(255)"))

(deftype universal-time () 
  "A positive integer as returned by GET-UNIVERSAL-TIME."
  '(integer 1 *))

(defmethod database-get-type-specifier ((type (eql 'universal-time)) args database db-type)
  (declare (ignore args database db-type))
  "BIGINT")

(defmethod database-get-type-specifier ((type (eql 'wall-time)) args database db-type)
  (declare (ignore args database db-type))
  "TIMESTAMP")

(defmethod database-get-type-specifier ((type (eql 'duration)) args database db-type)
  (declare (ignore database args db-type))
  "VARCHAR")

(defmethod database-get-type-specifier ((type (eql 'money)) args database db-type)
  (declare (ignore database args db-type))
  "INT8")

(deftype raw-string (&optional len)
  "A string which is not trimmed when retrieved from the database"
  `(string ,len))

(defmethod database-get-type-specifier ((type (eql 'raw-string)) args database db-type)
  (declare (ignore database db-type))
  (if args
      (format nil "VARCHAR(~A)" (car args))
      "VARCHAR"))

(defmethod database-get-type-specifier ((type (eql 'float)) args database db-type)
  (declare (ignore database db-type))
  (if args
      (format nil "FLOAT(~A)" (car args))
      "FLOAT"))

(defmethod database-get-type-specifier ((type (eql 'long-float)) args database db-type)
  (declare (ignore database db-type))
  (if args
      (format nil "FLOAT(~A)" (car args))
      "FLOAT"))

(defmethod database-get-type-specifier ((type (eql 'boolean)) args database db-type)
  (declare (ignore args database db-type))
  "BOOL")

(defmethod database-output-sql-as-type (type val database db-type)
  (declare (ignore type database db-type))
  val)

(defmethod database-output-sql-as-type ((type (eql 'list)) val database db-type)
  (declare (ignore database db-type))
  (progv '(*print-circle* *print-array*) '(t t)
    (let ((escaped (prin1-to-string val)))
      (substitute-char-string
       escaped #\Null " "))))

(defmethod database-output-sql-as-type ((type (eql 'symbol)) val database db-type)
  (declare (ignore database db-type))
  (if (keywordp val)
      (symbol-name val)
      (if val
          (concatenate 'string
                       (package-name (symbol-package val))
                       "::"
                       (symbol-name val))
          "")))

(defmethod database-output-sql-as-type ((type (eql 'keyword)) val database db-type)
  (declare (ignore database db-type))
  (if val
      (symbol-name val)
      ""))

(defmethod database-output-sql-as-type ((type (eql 'vector)) val database db-type)
  (declare (ignore database db-type))
  (progv '(*print-circle* *print-array*) '(t t)
    (prin1-to-string val)))

(defmethod database-output-sql-as-type ((type (eql 'array)) val database db-type)
  (declare (ignore database db-type))
  (progv '(*print-circle* *print-array*) '(t t)
    (prin1-to-string val)))

(defmethod database-output-sql-as-type ((type (eql 'boolean)) val database db-type)
  (declare (ignore database db-type))
  (if val "t" "f"))

(defmethod database-output-sql-as-type ((type (eql 'string)) val database db-type)
  (declare (ignore database db-type))
  val)

(defmethod database-output-sql-as-type ((type (eql 'simple-string))
					val database db-type)
  (declare (ignore database db-type))
  val)

(defmethod database-output-sql-as-type ((type (eql 'simple-base-string))
					val database db-type)
  (declare (ignore database db-type))
  val)

(defmethod read-sql-value (val type database db-type)
  (declare (ignore type database db-type))
  (read-from-string val))

(defmethod read-sql-value (val (type (eql 'string)) database db-type)
  (declare (ignore database db-type))
  val)

(defmethod read-sql-value (val (type (eql 'simple-string)) database db-type)
  (declare (ignore database db-type))
  val)

(defmethod read-sql-value (val (type (eql 'simple-base-string)) database db-type)
  (declare (ignore database db-type))
  val)

(defmethod read-sql-value (val (type (eql 'raw-string)) database db-type)
  (declare (ignore database db-type))
  val)

(defmethod read-sql-value (val (type (eql 'keyword)) database db-type)
  (declare (ignore database db-type))
  (when (< 0 (length val))
    (intern (symbol-name-default-case val) 
	    (find-package '#:keyword))))

(defmethod read-sql-value (val (type (eql 'symbol)) database db-type)
  (declare (ignore database db-type))
  (when (< 0 (length val))
    (unless (string= val (symbol-name-default-case "NIL"))
      (intern (symbol-name-default-case val)
              (symbol-package *update-context*)))))

(defmethod read-sql-value (val (type (eql 'integer)) database db-type)
  (declare (ignore database db-type))
  (etypecase val
    (string
     (unless (string-equal "NIL" val)
       (parse-integer val)))
    (number val)))

(defmethod read-sql-value (val (type (eql 'bigint)) database db-type)
  (declare (ignore database db-type))
  (etypecase val
    (string
     (unless (string-equal "NIL" val)
       (parse-integer val)))
    (number val)))

(defmethod read-sql-value (val (type (eql 'float)) database db-type)
  (declare (ignore database db-type))
  ;; writing 1.0 writes 1, so we we *really* want a float, must do (float ...)
  (etypecase val
    (string
     (float (read-from-string val)))
    (float
     val)))

(defmethod read-sql-value (val (type (eql 'boolean)) database db-type)
  (declare (ignore database db-type))
  (equal "t" val))

(defmethod read-sql-value (val (type (eql 'univeral-time)) database db-type)
  (declare (ignore database db-type))
  (unless (eq 'NULL val)
    (etypecase val
      (string
       (parse-integer val))
      (number val))))

(defmethod read-sql-value (val (type (eql 'wall-time)) database db-type)
  (declare (ignore database db-type))
  (unless (eq 'NULL val)
    (parse-timestring val)))

(defmethod read-sql-value (val (type (eql 'duration)) database db-type)
  (declare (ignore database db-type))
  (unless (or (eq 'NULL val)
              (equal "NIL" val))
    (parse-timestring val)))

;; ------------------------------------------------------------
;; Logic for 'faulting in' :join slots

;; this works, but is inefficient requiring (+ 1 n-rows)
;; SQL queries
#+ignore
(defun fault-join-target-slot (class object slot-def)
  (let* ((res (fault-join-slot-raw class object slot-def))
	 (dbi (view-class-slot-db-info slot-def))
	 (target-name (gethash :target-slot dbi))
	 (target-class (find-class target-name)))
    (when res
      (mapcar (lambda (obj)
		(list 
		 (car
		  (fault-join-slot-raw 
		   target-class
		   obj
		   (find target-name (class-slots (class-of obj))
			 :key #'slot-definition-name)))
		 obj))
	      res)
      #+ignore ;; this doesn't work when attempting to call slot-value
      (mapcar (lambda (obj)
		(cons obj (slot-value obj ts))) res))))

(defun fault-join-target-slot (class object slot-def)
  (let* ((dbi (view-class-slot-db-info slot-def))
	 (ts (gethash :target-slot dbi))
	 (jc (gethash :join-class dbi))
	 (ts-view-table (view-table (find-class ts)))
	 (jc-view-table (view-table (find-class jc)))
	 (tdbi (view-class-slot-db-info 
		(find ts (class-slots (find-class jc))
		      :key #'slot-definition-name)))
	 (retrieval (gethash :retrieval tdbi))
	 (jq (join-qualifier class object slot-def))
	 (key (slot-value object (gethash :home-key dbi))))
    (when jq
      (ecase retrieval
	(:immediate
	 (let ((res
		(find-all (list ts) 
			  :inner-join (sql-expression :table jc-view-table)
			  :on (sql-operation 
			       '==
			       (sql-expression 
				:attribute (gethash :foreign-key tdbi) 
				:table ts-view-table)
			       (sql-expression 
				:attribute (gethash :home-key tdbi) 
				:table jc-view-table))
			  :where jq
			  :result-types :auto)))
	   (mapcar #'(lambda (i)
		       (let* ((instance (car i))
			      (jcc (make-instance jc :view-database (view-database instance))))
			 (setf (slot-value jcc (gethash :foreign-key dbi)) 
			       key)
			 (setf (slot-value jcc (gethash :home-key tdbi)) 
			       (slot-value instance (gethash :foreign-key tdbi)))
		      (list instance jcc)))
		   res)))
	(:deferred
	    ;; just fill in minimal slots
	    (mapcar
	     #'(lambda (k)
		 (let ((instance (make-instance ts :view-database (view-database object)))
		       (jcc (make-instance jc :view-database (view-database object)))
		       (fk (car k)))
		   (setf (slot-value instance (gethash :home-key tdbi)) fk)
		   (setf (slot-value jcc (gethash :foreign-key dbi)) 
			 key)
		   (setf (slot-value jcc (gethash :home-key tdbi)) 
			 fk)
		   (list instance jcc)))
	     (select (sql-expression :attribute (gethash :foreign-key tdbi) :table jc-view-table)
		     :from (sql-expression :table jc-view-table)
		     :where jq)))))))


;;; Remote Joins

(defvar *default-update-objects-max-len* nil
  "The default value to use for the MAX-LEN keyword argument to
  UPDATE-OBJECT-JOINS.")

(defun update-objects-joins (objects &key (slots t) (force-p t)
			    class-name (max-len
			    *default-update-objects-max-len*))
  "Updates from the records of the appropriate database tables
the join slots specified by SLOTS in the supplied list of View
Class instances OBJECTS.  SLOTS is t by default which means that
all join slots with :retrieval :immediate are updated. CLASS-NAME
is used to specify the View Class of all instance in OBJECTS and
default to nil which means that the class of the first instance
in OBJECTS is used. FORCE-P is t by default which means that all
join slots are updated whereas a value of nil means that only
unbound join slots are updated. MAX-LEN defaults to
*DEFAULT-UPDATE-OBJECTS-MAX-LEN* and when non-nil specifies that
UPDATE-OBJECT-JOINS may issue multiple database queries with a
maximum of MAX-LEN instances updated in each query."
  (assert (or (null max-len) (plusp max-len)))
  (when objects
    (unless class-name
      (setq class-name (class-name (class-of (first objects)))))
    (let* ((class (find-class class-name))
	   (class-slots (ordered-class-slots class))
	   (slotdefs 
	    (if (eq t slots)
		(generate-retrieval-joins-list class :deferred)
	      (remove-if #'null
			 (mapcar #'(lambda (name)
				     (let ((slotdef (find name class-slots :key #'slot-definition-name)))
				       (unless slotdef
					 (warn "Unable to find slot named ~S in class ~S." name class))
				       slotdef))
				 slots)))))
      (dolist (slotdef slotdefs)
	(let* ((dbi (view-class-slot-db-info slotdef))
	       (slotdef-name (slot-definition-name slotdef))
	       (foreign-key (gethash :foreign-key dbi))
	       (home-key (gethash :home-key dbi))
	       (object-keys
		(remove-duplicates
		 (if force-p
		     (mapcar #'(lambda (o) (slot-value o home-key)) objects)
		   (remove-if #'null
			      (mapcar
			       #'(lambda (o) (if (slot-boundp o slotdef-name)
						 nil
					       (slot-value o home-key)))
			       objects)))))
	       (n-object-keys (length object-keys))
	       (query-len (or max-len n-object-keys)))
	  
	  (do ((i 0 (+ i query-len)))
	      ((>= i n-object-keys))
	    (let* ((keys (if max-len
			     (subseq object-keys i (min (+ i query-len) n-object-keys))
			   object-keys))
		   (results (find-all (list (gethash :join-class dbi))
				      :where (make-instance 'sql-relational-exp
					       :operator 'in
					       :sub-expressions (list (sql-expression :attribute foreign-key)
								      keys))
				      :result-types :auto
				      :flatp t)))
	      (dolist (object objects)
		(when (or force-p (not (slot-boundp object slotdef-name)))
		  (let ((res (find (slot-value object home-key) results 
				   :key #'(lambda (res) (slot-value res foreign-key))
				   :test #'equal)))
		    (when res
		      (setf (slot-value object slotdef-name) res)))))))))))
  (values))
  
(defun fault-join-slot-raw (class object slot-def)
  (let* ((dbi (view-class-slot-db-info slot-def))
	 (jc (gethash :join-class dbi)))
    (let ((jq (join-qualifier class object slot-def)))
      (when jq 
        (select jc :where jq :flatp t :result-types nil)))))

(defun fault-join-slot (class object slot-def)
  (let* ((dbi (view-class-slot-db-info slot-def))
	 (ts (gethash :target-slot dbi)))
    (if (and ts (gethash :set dbi))
	(fault-join-target-slot class object slot-def)
	(let ((res (fault-join-slot-raw class object slot-def)))
	  (when res
	    (cond
	      ((and ts (not (gethash :set dbi)))
	       (mapcar (lambda (obj) (slot-value obj ts)) res))
	      ((and (not ts) (not (gethash :set dbi)))
	       (car res))
	      ((and (not ts) (gethash :set dbi))
	       res)))))))

(defun join-qualifier (class object slot-def)
    (declare (ignore class))
    (let* ((dbi (view-class-slot-db-info slot-def))
	   (jc (find-class (gethash :join-class dbi)))
	   ;;(ts (gethash :target-slot dbi))
	   ;;(tsdef (if ts (slotdef-for-slot-with-class ts jc)))
	   (foreign-keys (gethash :foreign-key dbi))
	   (home-keys (gethash :home-key dbi)))
      (when (every #'(lambda (slt)
		       (and (slot-boundp object slt)
                            (not (null (slot-value object slt)))))
		   (if (listp home-keys) home-keys (list home-keys)))
	(let ((jc
               (mapcar #'(lambda (hk fk)
                           (let ((fksd (slotdef-for-slot-with-class fk jc)))
                             (sql-operation '==
                                            (typecase fk
                                              (symbol
                                               (sql-expression
                                                :attribute
                                                (view-class-slot-column fksd)
                                                :table (view-table jc)))
                                              (t fk))
                                            (typecase hk
                                              (symbol
                                               (slot-value object hk))
                                              (t
                                               hk)))))
                       (if (listp home-keys)
                           home-keys
                           (list home-keys))
                       (if (listp foreign-keys)
                           foreign-keys
                           (list foreign-keys)))))
          (when jc
            (if (> (length jc) 1)
                (apply #'sql-and jc)
                jc))))))

;; FIXME: add retrieval immediate for efficiency
;; For example, for (select 'employee-address) in test suite =>
;; select addr.*,ea_join.* FROM addr,ea_join WHERE ea_join.aaddressid=addr.addressid\g

(defun build-objects (vals sclasses immediate-join-classes sels immediate-joins database refresh flatp instances)
  "Used by find-all to build objects."
  (labels ((build-object (vals vclass jclasses selects immediate-selects instance)
	     (let* ((db-vals (butlast vals (- (list-length vals)
					      (list-length selects))))
		    (obj (if instance instance (make-instance (class-name vclass) :view-database database)))
		    (join-vals (subseq vals (list-length selects)))
		    (joins (mapcar #'(lambda (c) (when c (make-instance c :view-database database)))
				   jclasses)))
	       ;;(format t "db-vals: ~S, join-values: ~S~%" db-vals join-vals)
	       ;; use refresh keyword here 
	       (setf obj (get-slot-values-from-view obj (mapcar #'car selects) db-vals))
	       (mapc #'(lambda (jc) (get-slot-values-from-view jc (mapcar #'car immediate-selects) join-vals))
		     joins)
	       (mapc
		#'(lambda (jc) 
		    (let ((slot (find (class-name (class-of jc)) (class-slots vclass) 
				      :key #'(lambda (slot) 
					       (when (and (eq :join (view-class-slot-db-kind slot))
							  (eq (slot-definition-name slot)
							      (gethash :join-class (view-class-slot-db-info slot))))
						 (slot-definition-name slot))))))
		      (when slot
			(setf (slot-value obj (slot-definition-name slot)) jc))))
		joins)
	       (when refresh (instance-refreshed obj))
	       obj)))
    (let* ((objects
	    (mapcar #'(lambda (sclass jclass sel immediate-join instance) 
			(prog1
			    (build-object vals sclass jclass sel immediate-join instance)
			  (setf vals (nthcdr (+ (list-length sel) (list-length immediate-join))
					     vals))))
		    sclasses immediate-join-classes sels immediate-joins instances)))
      (if (and flatp (= (length sclasses) 1))
	  (car objects)
	objects))))

(defun find-all (view-classes 
		 &rest args
		 &key all set-operation distinct from where group-by having 
		      order-by offset limit refresh flatp result-types 
                      inner-join on 
		      (database *default-database*)
		      instances)
  "Called by SELECT to generate object query results when the
  View Classes VIEW-CLASSES are passed as arguments to SELECT."
  (declare (ignore all set-operation group-by having offset limit inner-join on)
           (optimize (debug 3) (speed 1)))
  (labels ((ref-equal (ref1 ref2)
	     (equal (sql ref1)
		    (sql ref2)))
	   (table-sql-expr (table)
	     (sql-expression :table (view-table table)))
	   (tables-equal (table-a table-b)
	     (when (and table-a table-b)
	       (string= (string (slot-value table-a 'name))
			(string (slot-value table-b 'name))))))
    (remf args :from)
    (remf args :where)
    (remf args :flatp)
    (remf args :additional-fields)
    (remf args :result-types)
    (remf args :instances)
    (let* ((*db-deserializing* t)
	   (sclasses (mapcar #'find-class view-classes))
	   (immediate-join-slots 
	    (mapcar #'(lambda (c) (generate-retrieval-joins-list c :immediate)) sclasses))
	   (immediate-join-classes
	    (mapcar #'(lambda (jcs)
			(mapcar #'(lambda (slotdef)
				    (find-class (gethash :join-class (view-class-slot-db-info slotdef))))
				jcs))
		    immediate-join-slots))
	   (immediate-join-sels (mapcar #'generate-immediate-joins-selection-list sclasses))
	   (sels (mapcar #'generate-selection-list sclasses))
	   (fullsels (apply #'append (mapcar #'append sels immediate-join-sels)))
	   (sel-tables (collect-table-refs where))
	   (tables (remove-if #'null
			      (remove-duplicates (append (mapcar #'table-sql-expr sclasses)
							 (mapcar #'(lambda (jcs)
								     (mapcan #'(lambda (jc)
										 (when jc (table-sql-expr jc)))
									     jcs))
								 immediate-join-classes)
							 sel-tables)
						 :test #'tables-equal)))
	   (order-by-slots (mapcar #'(lambda (ob) (if (atom ob) ob (car ob)))
				   (listify order-by))))
				 
      (dolist (ob order-by-slots)
	(when (and ob (not (member ob (mapcar #'cdr fullsels)
				   :test #'ref-equal)))
	  (setq fullsels 
	    (append fullsels (mapcar #'(lambda (att) (cons nil att))
				     order-by-slots)))))
      (dolist (ob (listify distinct))
	(when (and (typep ob 'sql-ident) 
		   (not (member ob (mapcar #'cdr fullsels) 
				:test #'ref-equal)))
	  (setq fullsels 
	      (append fullsels (mapcar #'(lambda (att) (cons nil att))
				       (listify ob))))))
      (mapcar #'(lambda (vclass jclasses jslots)
		  (when jclasses
		    (mapcar
		     #'(lambda (jclass jslot)
			 (let ((dbi (view-class-slot-db-info jslot)))
			   (setq where
				 (append
				  (list (sql-operation '==
						      (sql-expression
						       :attribute (gethash :foreign-key dbi)
						       :table (view-table jclass))
						      (sql-expression
						       :attribute (gethash :home-key dbi)
						       :table (view-table vclass))))
				  (when where (listify where))))))
		     jclasses jslots)))
	      sclasses immediate-join-classes immediate-join-slots)
      (let* ((rows (apply #'select 
			  (append (mapcar #'cdr fullsels)
				  (cons :from 
					(list (append (when from (listify from)) 
						      (listify tables)))) 
				  (list :result-types result-types)
				  (when where (list :where where))
				  args)))
	     (instances-to-add (- (length rows) (length instances)))
	     (perhaps-extended-instances
	      (if (plusp instances-to-add)
		  (append instances (do ((i 0 (1+ i))
					 (res nil))
					((= i instances-to-add) res)
				      (push (make-list (length sclasses) :initial-element nil) res)))
		instances))
	     (objects (mapcar 
		       #'(lambda (row instance)
			   (build-objects row sclasses immediate-join-classes sels
					  immediate-join-sels database refresh flatp 
					  (if (and flatp (atom instance))
					      (list instance)
					    instance)))
		       rows perhaps-extended-instances)))
	objects))))

(defmethod instance-refreshed ((instance standard-db-object)))

(defun select (&rest select-all-args) 
   "Executes a query on DATABASE, which has a default value of
*DEFAULT-DATABASE*, specified by the SQL expressions supplied
using the remaining arguments in SELECT-ALL-ARGS. The SELECT
argument can be used to generate queries in both functional and
object oriented contexts. 

In the functional case, the required arguments specify the
columns selected by the query and may be symbolic SQL expressions
or strings representing attribute identifiers. Type modified
identifiers indicate that the values selected from the specified
column are converted to the specified lisp type. The keyword
arguments ALL, DISTINCT, FROM, GROUP-by, HAVING, ORDER-BY,
SET-OPERATION and WHERE are used to specify, using the symbolic
SQL syntax, the corresponding components of the SQL query
generated by the call to SELECT. RESULT-TYPES is a list of
symbols which specifies the lisp type for each field returned by
the query. If RESULT-TYPES is nil all results are returned as
strings whereas the default value of :auto means that the lisp
types are automatically computed for each field. FIELD-NAMES is t
by default which means that the second value returned is a list
of strings representing the columns selected by the query. If
FIELD-NAMES is nil, the list of column names is not returned as a
second value. 

In the object oriented case, the required arguments to SELECT are
symbols denoting View Classes which specify the database tables
to query. In this case, SELECT returns a list of View Class
instances whose slots are set from the attribute values of the
records in the specified table. Slot-value is a legal operator
which can be employed as part of the symbolic SQL syntax used in
the WHERE keyword argument to SELECT. REFRESH is nil by default
which means that the View Class instances returned are retrieved
from a cache if an equivalent call to SELECT has previously been
issued. If REFRESH is true, the View Class instances returned are
updated as necessary from the database and the generic function
INSTANCE-REFRESHED is called to perform any necessary operations
on the updated instances.

In both object oriented and functional contexts, FLATP has a
default value of nil which means that the results are returned as
a list of lists. If FLATP is t and only one result is returned
for each record selected in the query, the results are returned
as elements of a list."

  (flet ((select-objects (target-args)
           (and target-args
                (every #'(lambda (arg)
                           (and (symbolp arg)
                                (find-class arg nil)))
                       target-args))))
    (multiple-value-bind (target-args qualifier-args)
        (query-get-selections select-all-args)
      (unless (or *default-database* (getf qualifier-args :database))
	(signal-no-database-error nil))
   
	(cond
	  ((select-objects target-args)
	   (let ((caching (getf qualifier-args :caching t))
		 (result-types (getf qualifier-args :result-types :auto))
		 (refresh (getf qualifier-args :refresh nil))
		 (database (or (getf qualifier-args :database) *default-database*))
		 (order-by (getf qualifier-args :order-by)))
	     (remf qualifier-args :caching)
	     (remf qualifier-args :refresh)
	     (remf qualifier-args :result-types)
	     
	     
	     ;; Add explicity table name to order-by if not specified and only
	     ;; one selected table. This is required so FIND-ALL won't duplicate
	     ;; the field
	     (when (and order-by (= 1 (length target-args)))
	       (let ((table-name  (view-table (find-class (car target-args))))
		     (order-by-list (copy-seq (listify order-by))))
		 
		 (loop for i from 0 below (length order-by-list)
		     do (etypecase (nth i order-by-list)
			  (sql-ident-attribute
			   (unless (slot-value (nth i order-by-list) 'qualifier)
			     (setf (slot-value (nth i order-by-list) 'qualifier) table-name)))
			  (cons
			   (unless (slot-value (car (nth i order-by-list)) 'qualifier)
			     (setf (slot-value (car (nth i order-by-list)) 'qualifier) table-name)))))
		 (setf (getf qualifier-args :order-by) order-by-list)))
	
	     (cond
	       ((null caching)
		(apply #'find-all target-args
		       (append qualifier-args (list :result-types result-types))))
	       (t
		(let ((cached (records-cache-results target-args qualifier-args database)))
		  (cond
		    ((and cached (not refresh))
		     cached)
		    ((and cached refresh)
		     (let ((results (apply #'find-all (append (list target-args) qualifier-args `(:instances ,cached :result-types :auto)))))
		       (setf (records-cache-results target-args qualifier-args database) results)
		       results))
		    (t
		     (let ((results (apply #'find-all target-args (append qualifier-args
									  '(:result-types :auto)))))
		       (setf (records-cache-results target-args qualifier-args database) results)
		       results))))))))
	  (t
	   (let* ((expr (apply #'make-query select-all-args))
		  (specified-types
		   (mapcar #'(lambda (attrib)
			       (if (typep attrib 'sql-ident-attribute)
				   (let ((type (slot-value attrib 'type)))
				     (if type
					 type
					 t))
				   t))
			   (slot-value expr 'selections))))
	     (destructuring-bind (&key (flatp nil)
				       (result-types :auto)
				       (field-names t) 
				       (database *default-database*)
				       &allow-other-keys)
		 qualifier-args
	       (query expr :flatp flatp 
		      :result-types 
		      ;; specifying a type for an attribute overrides result-types
		      (if (some #'(lambda (x) (not (eq t x))) specified-types) 
			  specified-types
			  result-types)
		      :field-names field-names
		      :database database))))))))

(defun compute-records-cache-key (targets qualifiers)
  (list targets
	(do ((args *select-arguments* (cdr args))
	     (results nil))
	    ((null args) results)
	  (let* ((arg (car args))
		 (value (getf qualifiers arg)))
	    (when value
	      (push (list arg
			  (typecase value
			    (cons (cons (sql (car value)) (cdr value)))
			    (%sql-expression (sql value))
			    (t value)))
		    results))))))

(defun records-cache-results (targets qualifiers database)
  (when (record-caches database)
    (gethash (compute-records-cache-key targets qualifiers) (record-caches database)))) 

(defun (setf records-cache-results) (results targets qualifiers database)
  (unless (record-caches database)
    (setf (record-caches database)
	  (make-hash-table :test 'equal
			   #+allegro :values #+allegro :weak)))
  (setf (gethash (compute-records-cache-key targets qualifiers)
		 (record-caches database)) results)
  results)

(defun update-cached-results (targets qualifiers database)
  ;; FIXME: this routine will need to update slots in cached objects, perhaps adding or removing objects from cached
  ;; for now, dump cache entry and perform fresh search
  (let ((res (apply #'find-all targets qualifiers)))
    (setf (gethash (compute-records-cache-key targets qualifiers)
		   (record-caches database)) res)
    res))

