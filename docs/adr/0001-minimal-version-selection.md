# 1. Minimal version selection, not a solver

Date: 2026-08-02 · Status: accepted

## Context

npm and Cargo resolve dependencies by search. A solver explores the version
space looking for an assignment that satisfies every constraint, and when none
exists you get a conflict report phrased in terms of the search: which
constraints were tried, which were dropped, what to relax.

Two costs follow that are rarely counted. The answer depends on the solver —
its order, its heuristics, its version — so "works on my machine" survives
into dependency resolution. And the algorithm is large enough that nobody
reads it, which means nobody can predict it.

Go selects the maximum of the required versions, per module, and stops.

## Decision

Minimal version selection.

```
selected(module) = max { version : (module, version) is required }
```

There is no conflict case. Two requirements for different versions of one
module are not a contradiction; they are two lower bounds, and the larger
satisfies both. So there is no backtracking, no heuristic, and nothing for a
solver version to disagree about.

The selected version is a *function* of the requirement set. `seed/resolver/`
is that function, in the language's executable slice, and the gate proves the
consequence directly: the same requirements in a different order produce the
same resolution, byte for byte, read out of the recorded output rather than
asserted about it.

## Consequences

A lock is reproducible because resolution is a function, not because the
lockfile froze the output of something unpredictable. That is a different and
stronger claim than "we ship a lockfile".

Adding a dependency cannot move a version nobody asked to move. Under a solver
the whole assignment is recomputed and unrelated packages drift; under MVS a
new requirement raises exactly the lower bounds it names.

**The cost, stated plainly:** you get the lowest version that satisfies
everyone, so a newly published release does not arrive until something asks
for it. Projects that want the newest thing must say so. That is a cost only
if the drift was the feature.

**The second cost:** MVS assumes versions are backward compatible within a
major line, because it will happily select a higher one to satisfy someone
else. Go leans on import-path versioning for the major boundary; the
equivalent decision here is open and belongs to its own ADR before any
registry exists.

## Evidence

Breaking it is caught by name. Selecting the highest published version
instead — npm's default, and a one-line change here:

```
pm: FAIL: two requirements select the larger, not the newest published:
    expected '10 1 5 7 ', got '10 1 7 7 '
```

Making the maximum order-dependent fails the unit test that exists for exactly
that property, `test_the_answer_does_not_depend_on_order`.
