;;; erc-scenarios-base-reconnect.el --- Base-reconnect scenarios -*- lexical-binding: t -*-

;; Copyright (C) 2022-2025 Free Software Foundation, Inc.

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Code:

(require 'ert-x)
(eval-and-compile
  (let ((load-path (cons (ert-resource-directory) load-path)))
    (require 'erc-scenarios-common)))

(eval-when-compile (require 'erc-join))

;; This ensures we only reconnect `erc-server-reconnect-attempts'
;; (rather than infinitely many) times, which can easily happen when
;; tweaking code related to process sentinels in erc-backend.el.

(ert-deftest erc-scenarios-base-reconnect-timer ()
  :tags '(:expensive-test)
  (erc-scenarios-common-with-cleanup
      ((erc-scenarios-common-dialog "base/reconnect")
       (dumb-server (erc-d-run "localhost" t 'timer 'timer 'timer-last))
       (port (process-contact dumb-server :service))
       (expect (erc-d-t-make-expecter))
       (erc-server-reconnect-function #'erc-server-delayed-reconnect)
       (erc-server-auto-reconnect t)
       erc-autojoin-channels-alist
       erc-server-buffer)

    (ert-info ("Connect to foonet")
      (setq erc-server-buffer (erc :server "127.0.0.1"
                                   :port port
                                   :nick "tester"
                                   :password "changeme"
                                   :full-name "tester"))
      (with-current-buffer erc-server-buffer
        (should (string= (buffer-name) (format "127.0.0.1:%d" port)))))

    (ert-info ("Server tries to connect thrice (including initial attempt)")
      (with-current-buffer erc-server-buffer
        (dotimes (n 3)
          (ert-info ((format "Attempt %d" n))
            (funcall expect 3 "Opening connection")
            (funcall expect 2 "Password incorrect")
            (funcall expect 2 "Connection failed!")
            (funcall expect 2 "Re-establishing connection")))
        (ert-info ("Prev attempt was final")
          (erc-d-t-absent-for 1 "Opening connection" (point)))))

    (ert-info ("Server buffer is unique and temp name is absent")
      (should (equal (list (get-buffer (format "127.0.0.1:%d" port)))
                     (erc-scenarios-common-buflist "127.0.0.1"))))))

;; Upon reconnecting, playback for channel and target buffers is
;; routed correctly.  Autojoin is irrelevant here, but for the
;; skeptical, see `erc-scenarios-common--join-network-id', which
;; overlaps with this and includes spurious JOINs ignored by the
;; server.

(ert-deftest erc-scenarios-base-association-reconnect-playback ()
  :tags '(:expensive-test)
  (erc-scenarios-common-with-cleanup
      ((erc-scenarios-common-dialog "base/assoc/reconplay")
       (erc-server-flood-penalty 0.1)
       (erc-server-flood-margin 30)
       (dumb-server (erc-d-run "localhost" t 'foonet 'again))
       (port (process-contact dumb-server :service))
       (expect (erc-d-t-make-expecter))
       erc-autojoin-channels-alist
       erc-server-buffer-foo)

    (ert-info ("Connect to foonet")
      (setq erc-server-buffer-foo (erc :server "127.0.0.1"
                                       :port port
                                       :nick "tester"
                                       :password "changeme"
                                       :full-name "tester"))
      (with-current-buffer erc-server-buffer-foo
        (should (string= (buffer-name) (format "127.0.0.1:%d" port)))))

    (ert-info ("Setup")

      (ert-info ("Server buffer is unique and temp name is absent")
        (erc-d-t-wait-for 3 (get-buffer "foonet"))
        (should-not (erc-scenarios-common-buflist "127.0.0.1")))

      (ert-info ("Channel buffer #chan playback received")
        (with-current-buffer (erc-d-t-wait-for 8 (get-buffer "#chan"))
          (funcall expect 10 "But purgatory")))

      (ert-info ("Ask for help from services or bouncer bot")
        (with-current-buffer erc-server-buffer-foo
          (erc-cmd-MSG "*status help")))

      (ert-info ("Help received")
        (with-current-buffer (erc-d-t-wait-for 5 (get-buffer "*status"))
          (funcall expect 10 "Rehash")))

      (ert-info ("#chan convo done")
        (with-current-buffer "#chan"
          (funcall expect 10 "most egregious indignity"))))

    ;; KLUDGE (see note above test)
    (should erc-autojoin-channels-alist)
    (setq erc-autojoin-channels-alist nil)

    (with-current-buffer erc-server-buffer-foo
      (erc-cmd-QUIT "")
      (erc-d-t-wait-for 4 (not (erc-server-process-alive)))
      (erc-cmd-RECONNECT))

    (ert-info ("Channel buffer found and associated")
      (with-current-buffer "#chan"
        (funcall expect 10 "Wilt thou rest damned")))

    (ert-info ("Help buffer found and associated")
      (with-current-buffer "*status"
        (erc-scenarios-common-say "help")
        (funcall expect 10 "Restart ZNC")))

    (ert-info ("#chan convo done")
      (with-current-buffer "#chan"
        (funcall expect 10 "here comes the lady")))))


(ert-deftest erc-scenarios-base-cancel-reconnect ()
  :tags '(:expensive-test)
  (erc-scenarios-common-with-cleanup
      ((erc-scenarios-common-dialog "base/reconnect")
       (dumb-server (erc-d-run "localhost" t 'timer 'timer 'timer-last))
       (port (process-contact dumb-server :service))
       (expect (erc-d-t-make-expecter))
       (erc-server-reconnect-function #'erc-server-delayed-reconnect)
       (erc-server-auto-reconnect t)
       erc-autojoin-channels-alist
       erc-server-buffer)

    (ert-info ("Connect to foonet")
      (setq erc-server-buffer (erc :server "127.0.0.1"
                                   :port port
                                   :nick "tester"
                                   :password "changeme"
                                   :full-name "tester"))
      (with-current-buffer erc-server-buffer
        (should (string= (buffer-name) (format "127.0.0.1:%d" port)))))

    (ert-info ("Two connection attempts, all stymied")
      (with-current-buffer erc-server-buffer
        (ert-info ("First two attempts behave normally")
          (dotimes (n 2)
            (ert-info ((format "Initial attempt %d" (1+ n)))
              (funcall expect 3 "Opening connection")
              (funcall expect 2 "Password incorrect")
              (funcall expect 2 "Connection failed!")
              (funcall expect 2 "Re-establishing connection"))))
        (ert-info ("/RECONNECT cancels timer but still attempts to connect")
          (erc-cmd-RECONNECT)
          (funcall expect 2 "Canceled")
          (funcall expect 3 "Opening connection")
          (funcall expect 2 "Password incorrect")
          (funcall expect 10 "Connection failed!")
          (funcall expect 2 "Re-establishing connection"))
        (ert-info ("Explicitly cancel timer")
          (erc-cmd-RECONNECT "cancel")
          (funcall expect 2 "Canceled")
          (erc-d-t-absent-for 1 "Opening connection" (point)))))

    (ert-info ("Server buffer is unique and temp name is absent")
      (should (equal (list (get-buffer (format "127.0.0.1:%d" port)))
                     (erc-scenarios-common-buflist "127.0.0.1"))))))

;;; erc-scenarios-base-reconnect.el ends here
