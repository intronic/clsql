;;;; -*- Mode: LISP; Syntax: ANSI-Common-Lisp; Base: 10 -*-
;;;; ======================================================================
;;;; File:    test-ooddl.lisp
;;;; Author:  Marcus Pearce <m.t.pearce@city.ac.uk>
;;;; Created: 30/03/2004
;;;; Updated: $Id$
;;;;
;;;; Tests for the CLSQL Object Oriented Data Definition Language
;;;; (OODDL).
;;;;
;;;; This file is part of CLSQL.
;;;;
;;;; CLSQL users are granted the rights to distribute and use this software
;;;; as governed by the terms of the Lisp Lesser GNU Public License
;;;; (http://opensource.franz.com/preamble.html), also known as the LLGPL.
;;;; ======================================================================


(in-package #:clsql-tests)

#.(clsql:locally-enable-sql-reader-syntax)

(setq *rt-ooddl*
      '(
	
;; Ensure slots inherited from standard-classes are :virtual
(deftest :ooddl/metaclass/1
    (values 
     (clsql-sys::view-class-slot-db-kind
      (clsql-sys::slotdef-for-slot-with-class 'extraterrestrial
                                             (find-class 'person)))
     (clsql-sys::view-class-slot-db-kind
      (clsql-sys::slotdef-for-slot-with-class 'hobby (find-class 'person))))
  :virtual :virtual)

;; Ensure all slots in view-class are view-class-effective-slot-definition
(deftest :ooddl/metaclass/2
    (values
     (every #'(lambda (slotd)
                (typep slotd 'clsql-sys::view-class-effective-slot-definition))
            (clsql-sys::class-slots (find-class 'person)))
     (every #'(lambda (slotd)
                (typep slotd 'clsql-sys::view-class-effective-slot-definition))
            (clsql-sys::class-slots (find-class 'employee)))
     (every #'(lambda (slotd)
                (typep slotd 'clsql-sys::view-class-effective-slot-definition))
            (clsql-sys::class-slots (find-class 'company))))
  t t t)

(deftest :ooddl/join/1
    (mapcar #'(lambda (e)
                (slot-value e 'companyid))
            (company-employees company1))
  (1 1 1 1 1 1 1 1 1 1))

(deftest :ooddl/join/2
    (slot-value (president company1) 'last-name)
  "Lenin")

(deftest :ooddl/join/3
    (slot-value (employee-manager employee2) 'last-name)
  "Lenin")

(deftest :ooddl/time/1
    (let* ((now (clsql-base:get-time)))
      (when (member *test-database-underlying-type* '(:postgresql :postgresql-socket))
        (clsql:execute-command "set datestyle to 'iso'"))
      (clsql:update-records [employee] :av-pairs `((birthday ,now))
                           :where [= [emplid] 1])
      (let ((dbobj (car (clsql:select 'employee :where [= [birthday] now]))))
        (values
         (slot-value dbobj 'last-name)
         (clsql-base:time= (slot-value dbobj 'birthday) now))))
  "Lenin" t)

(deftest :ooddl/time/2
    (let* ((now (clsql-base:get-time))
           (fail-index -1))
      (when (member *test-database-underlying-type* '(:postgresql :postgresql-socket))
        (clsql:execute-command "set datestyle to 'iso'"))
      (dotimes (x 40)
        (clsql:update-records [employee] :av-pairs `((birthday ,now))
                             :where [= [emplid] 1])
        (let ((dbobj (car (clsql:select 'employee :where [= [birthday] now]))))
          (unless (clsql-base:time= (slot-value dbobj 'birthday) now)
            (setf fail-index x))
          (setf now (clsql-base:roll now :day (* 10 x)))))
      fail-index)
  -1)

))

#.(clsql:restore-sql-reader-syntax-state)

