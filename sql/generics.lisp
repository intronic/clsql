;;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; *************************************************************************
;;;; FILE IDENTIFICATION
;;;;
;;;; Name:     generics.lisp
;;;; Purpose:  Generic function definitions for DB interfaces
;;;; Author:   Kevin M. Rosenberg based on
;;;; Created:  Apr 2004
;;;;
;;;; $Id: db-interface.lisp 9123 2004-04-21 20:34:42Z kevin $
;;;;
;;;; This file, part of CLSQL, is Copyright (c) 2002-2004 by Kevin M. Rosenberg
;;;;
;;;; CLSQL users are granted the rights to distribute and use this software
;;;; as governed by the terms of the Lisp Lesser GNU Public License
;;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;; *************************************************************************

(in-package #:clsql-sys)

(defgeneric update-record-from-slot (object slot &key database)
  (:documentation
   "Updates the value stored in the column represented by the
slot, specified by the CLOS slot name SLOT, of View Class
instance OBJECT. DATABASE defaults to *DEFAULT-DATABASE* and
specifies the database in which the update is made only if OBJECT
is not associated with a database. In this case, a record is
created in DATABASE and the attribute represented by SLOT is
initialised from the value of the supplied slots with other
attributes having default values. Furthermore, OBJECT becomes
associated with DATABASE."))

(defgeneric update-record-from-slots (object slots &key database)
  (:documentation 
   "Updates the values stored in the columns represented by the
slots, specified by the CLOS slot names SLOTS, of View Class
instance OBJECT. DATABASE defaults to *DEFAULT-DATABASE* and
specifies the database in which the update is made only if OBJECT
is not associated with a database. In this case, a record is
created in the appropriate table of DATABASE and the attributes
represented by SLOTS are initialised from the values of the
supplied slots with other attributes having default
values. Furthermore, OBJECT becomes associated with DATABASE."))

(defgeneric update-records-from-instance (object &key database)
  (:documentation
   "Using an instance of a View Class, OBJECT, update the table
that stores its instance data. DATABASE defaults to
*DEFAULT-DATABASE* and specifies the database in which the update
is made only if OBJECT is not associated with a database. In this
case, a record is created in the appropriate table of DATABASE
using values from the slot values of OBJECT, and OBJECT becomes
associated with DATABASE."))

(defgeneric delete-instance-records (object)
  (:documentation
   "Deletes the records represented by OBJECT in the appropriate
table of the database associated with OBJECT. If OBJECT is not
yet associated with a database, an error is signalled."))

(defgeneric update-instance-from-records (object &key database)
  (:documentation
   "Updates the slot values of the View Class instance OBJECT
using the attribute values of the appropriate table of DATABASE
which defaults to the database associated with OBJECT or, if
OBJECT is not associated with a database, *DEFAULT-DATABASE*.
Join slots are updated but instances of the class on which the
join is made are not updated."))

(defgeneric update-slot-from-record (object slot &key database)
  (:documentation
   "Updates the slot value, specified by the CLOS slot name SLOT,
of the View Class instance OBJECT using the attribute values of
the appropriate table of DATABASE which defaults to the database
associated with OBJECT or, if OBJECT is not associated with a
database, *DEFAULT-DATABASE*.  Join slots are updated but
instances of the class on which the join is made are not
updated."))

(defgeneric instance-refreshed (object) 
  (:documentation 
   "Provides a hook which is called within an object oriented
call to SELECT with a non-nil value of REFRESH when the View
Class instance OBJECT has been updated from the database. A
method specialised on STANDARD-DB-OBJECT is provided which has no
effects. Methods specialised on particular View Classes can be
used to specify any operations that need to be made on View
Classes instances which have been updated in calls to SELECT."))

(defgeneric update-slot-with-null (instance slotname slotdef)
  (:documentation "Called to update a slot when its column has a NULL
value.  If nulls are allowed for the column, the slot's value will be
nil, otherwise its value will be set to the result of calling
DATABASE-NULL-VALUE on the type of the slot."))

(defgeneric output-sql (expr database)
  )

(defgeneric output-sql-hash-key (arg database)
  )

(defgeneric collect-table-refs (sql)
  )
(defgeneric database-output-sql (arg database)
  )
(defgeneric database-constraint-description  (constraint database)
  )
(defgeneric database-pkey-constraint  (class database)
  )
(defgeneric database-constraint-statement  (constraints database)
  )
(defgeneric %install-class  (class database)
  )
(defgeneric database-generate-column-definition  (class slotdef database)
  )
(defgeneric update-slot-from-db  (instance slotdef val)
  )
(defgeneric key-value-from-db  (slotdef value database)
  )
(defgeneric get-slot-values-from-view  (obj slotdeflist values)
  )
(defgeneric database-output-sql-as-type  (type val database db-type)
  )
(defgeneric read-sql-value  (val type database db-type)
  )

