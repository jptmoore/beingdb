(lang dune 3.7)
(name beingdb)

(generate_opam_files true)

(source (github john/beingdb))
(license MIT)
(authors "John")
(maintainers "John")

(package
 (name beingdb)
 (allow_empty)
 (synopsis "Logic-based knowledge store with Git and Pack backends")
 (description "A dual-backend knowledge store using Irmin: Git for canonical predicates, Pack for runtime queries")
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
