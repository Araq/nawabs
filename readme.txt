=================================================================
                        Nawabs
=================================================================

Nawabs ("nobody agrees with this approach of building software") is a tool that
builds upon Nimble's package repository, but throws away the fragile versioning
specifications, instead it uses commit hashes.

Nawabs was built with the following design goals:

* Manage a collection of "packages". This collection is called a "workspace",
  a package is a git or mercurial repository.
* Build packages.
* Record the state of the workspace that used to compile/work to get
  "reproducible builds" (also called "Pinned Builds").

A pinned build is described by a "recipe": The recipe file is a NimScript that
can be executed again to get a reproducible build. It stores the project's
dependencies as well as the used commit hashes.

Recipe files are also version controlled.

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

``nawabs search keyword``
  Search through the list of available packages after *keyword*.

``nawabs build pkg``
  Nawabs clones 'pkg' (if it doesn't exist yet) and tries to build it.

``nawabs pinned pkg``
  Rebuilds 'pkg' in the same configuration that was successful the last time.

``nawabs update pkg``
  Updates 'pkg' and its dependencies to use the latest commits (aka ``git HEAD``).

For a complete list of commands, run ``nawabs --help``.


Scratchpad
==========

Nawabs allows to store arbitrary key/value pairs in a scratchpad that is
version controlled, so you cannot lose data. The scratchpad is the ``env``
subdirectory in the ``recipes_`` directory. You can use this to get
universal portable shell aliases::

  nawabs put nimtests nim c -r tests/testament/tester.nim all
  nawabs get nimtests
  nawabs run nimtests

The special variable "_" is set after every successful ``nawabs build`` command
to this very build command.
You can use ``nawabs run _`` or simply ``nawabs run`` to rerun the command.


(c) 2017 Andreas Rumpf
