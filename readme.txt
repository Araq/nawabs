=================================================================
       Nawabs
=================================================================

Nawabs ("nobody agrees with this approach of building software") is a tool that
builds upon Nimble's package repository, but throws away everything else.

Nawabs is the anti package manager, it builds Nim software packages with a
smart algorithm and it ignores versioning. The plan is to use a binary search
through tagged versions to figure out the most recent configuration that can
still build the software.

(c) 2016 Andreas Rumpf
