=================================================================
                        Nawabs
=================================================================

Nawabs ("nobody agrees with this approach of building software") is a tool that
builds upon Nimble's package repository, but throws away the fragile versioning
specifications, instead it uses commit hashes.

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

Nawabs always works within a "workspace". A workspace is a collection of
"packages".

To make a workspace out of the current working directory run ``nawabs init``.

Every direct child directory in the workspace is treated as a
package. Subdirectories are part of the package
search space if they end in an underscore. As an example consider this
directory layout:

  workspace/
    nimcore_/
      jester/
      compiler/

    c2nim/
    backup/
      c2nim

``c2nim`` is a package since it's a direct child of the workspace, ``jester``
and ``compiler`` are part of the workspace since they are under ``nimcore_``
which ends in an underscore. ``backup/c2nim`` is not part of the workspace
because ``backup`` doesn't end in an underscore.


Commands
========

``nawabs init``
  Make the current working directory your workspace.

``nawabs tinker pkg``
  Nawabs clones 'pkg' and tries to build it.

``nawabs pinned pkg``
  Rebuilds 'pkg' in the same configuration that was successful the last time.

``nawabs pinnedcmd pkg``
  Outputs the last command that was successful at building "pkg".

``nawabs update pkg``
  Rebuilds 'pkg' but updates 'pkg' and its dependencies to use the latest
  versions.

For a complete list of commands, run ``nawabs --help``.

(c) 2017 Andreas Rumpf
