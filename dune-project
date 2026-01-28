(lang dune 3.7)
(name beingdb)
(version 0.1.2)

(generate_opam_files true)

(source (github jptmoore/beingdb))
(license MIT)
(authors "John Moore <john.moore@zedstar.org>")
(maintainers "John Moore <jmoore@zedstar.org>")

(package
 (name beingdb)
 (allow_empty)
 (synopsis "Being DB — facts with history")
 (description "A lightweight knowledge store that tracks your facts in Git and serves fast queries from an optimised backend. Edit your data like code, compile snapshots, and query them at high speed.")
 (depends
  (ocaml (>= 4.14.0))
  dune
  (irmin (>= 3.7.0))
  (irmin-git (>= 3.7.0))
  (irmin-pack (>= 3.7.0))
  (dream (>= 1.0.0~alpha5))
  (lwt (>= 5.6.0))
  (logs (>= 0.7.0))
  (fmt (>= 0.9.0))
  (yojson (>= 2.0.0))
  (cmdliner (>= 1.1.0))
  (alcotest (and (>= 1.7.0) :with-test))
  (alcotest-lwt (and (>= 1.7.0) :with-test))))
