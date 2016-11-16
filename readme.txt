=================================================================
       Nawabs
=================================================================

Nawabs ("nobody agrees with this approach of building software") is a tool that
builds upon Nimble's package repository, but throws away everything else.

Nawabs is the anti package manager, it builds Nim software packages with a
smart algorithm and it ignores versioning.

Nawabs distinguishes between two different ways of building software:

1. Tinkering.
2. Reproducible builds. ("Pinned builds".)

"Tinkering" is based on an algorithm with rather adhoc rules, mimicing the way
a human being builds software "by hand". After tinkering is successful, nawabs
built the software package for you successfully and the steps to do so are
written to a "recipe" file. The recipe file is a NimScript that can be
executed again to get a reproducible build. It stores the project's dependencies
as well as the used commit hashes.

Recipe files are version controlled.

Nawabs always works within a "workspace". To make a workspace out of the
current working directory run ``nawabs init``.


Commands
========

``nawabs init``
  Make the current working directory your workspace.

``nawabs c nake``
  Nawabs clones 'nake' and tries to build it.

``nawabs pinned nake``
  Rebuilds 'nake' in the same configuration that was successful the last time.

``nawabs update nake``
  Rebuilds 'nake' but updates 'nake' and its dependencies to use the latest
  versions.


TODO
====

- Clearly distinguish between package name and build command to run the tinker
  algorithm with.
- Add support for reading nimble dependencies, if there is a ``.nimble`` file.
- Implement tinker hooks for manual interventions.


(c) 2016 Andreas Rumpf
