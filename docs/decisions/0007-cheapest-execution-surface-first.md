---
id: 0007
title: Always take the cheapest execution surface that will work
status: accepted
date: 2026-08-29
deciders: [Kunal, Claude]
tags: [architecture, runtime, cost]
---

# 0007. Always take the cheapest execution surface that will work

## Context

A computer-use agent can do most things more than one way. "Find `authCallback` in my
repository" can be `rg authCallback`, or it can be: open the editor, screenshot it, find the
search box, click it, type, screenshot again, read the results.

Both work. The first costs one command and about 50 tokens. The second costs six model calls,
four screenshots at roughly 1,500 tokens each, and perhaps forty seconds — and is far more
likely to fail, because every step can miss.

Pixel-driving everything is the standard failure mode of computer-use demos. It looks the most
impressive and it is the worst available strategy whenever anything else exists.

Two independent sources arrived at the same conclusion. Cua describes a "Computer-Use 2.0"
model in which coding, structured tools and UI automation are complementary surfaces rather
than a hierarchy of sophistication. openclicky, a small Swift menu-bar agent, independently
ships a routing ladder that ends with "native computer use fallback for complex GUI
interactions that other methods cannot handle".

## Options considered

### Option A — GUI for everything, because it is universal
- **For:** One code path. Works against any application, including ones with no API. Impressive.
- **Against:** Slowest, most expensive, least reliable option for the large majority of real
  tasks. Every step is a chance to misclick.

### Option B — Structured surfaces only, no GUI
- **For:** Fast, cheap, deterministic, verifiable.
- **Against:** Cannot touch anything without an API — which includes a great deal of what a
  person actually does on a Mac.

### Option C — All surfaces, ordered by cost, with an explicit selector
- **For:** Fast where speed is available, capable where it is not.
- **Against:** Every tool must be classified, and the classification must be right. A tool
  mislabelled as an API when it is really a GUI wrapper corrupts the ordering.

## Decision

We chose **Option C**. `ActionSurface` is a property of every tool in the registry, and it is
`Comparable`, so "prefer the cheapest surface" is a sort rather than a special case:

```
api  <  code  <  structuredBrowser  <  gui  <  human
```

`SurfaceSelector.choose` returns the cheapest surface the contract's authority permits. The
same ordering is stated in prose in the system prompt, as a preference rather than a
prohibition — a hard ban produces worse behaviour than a strong default, because there are real
cases for every surface.

Because: this single rule buys more perceived capability per line of code than anything else in
the harness. An agent that reaches for a command instead of a mouse feels like it knows what it
is doing, and one that clicks through a task a script would solve feels like it does not.

Note that `human` is on the ladder deliberately. Asking the user is a real surface with a real
cost, and putting it last in the same ordering is what stops "should I go ahead?" from being
the model's cheapest escape.

## Consequences

- **We now must:** classify every tool's surface correctly, including plugin-provided ones.
  A plugin that wraps a GUI must not declare itself an API.
- **We now must:** teach the ordering in the system prompt as well as enforcing it in the
  selector, since the model chooses which tool to ask for before the selector sees anything.
- **We can no longer:** add a capability as GUI-only without asking whether a structured path
  exists. That question becomes part of review.
- **We gain:** a coherent answer to "why was this slow?" — usually, because it used a surface
  further down the ladder than it needed to.

## Revisit when

Vision-model cost falls far enough, or GUI grounding becomes reliable enough, that the ordering
stops reflecting reality. That is a measurement, not an opinion: the trigger is the GUI path
beating the structured path on success rate *and* cost on our own eval tasks.
