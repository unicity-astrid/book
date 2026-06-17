# Introduction

Astrid is an operating system for AI agents. It treats an agent the way an operating system treats a process: it boots the agent, isolates it, grants it exactly the authority it needs and no more, and writes down everything it does in a ledger that cannot be quietly rewritten. It does not trust the thing it is running. Because of how it is built, it does not need to.

Concretely: an agent runs as WebAssembly inside a sandbox with no ambient authority. Every capability it has, every file path, every network host, every tool, is a signed grant the host checks before it moves a byte. Every action it takes is appended to a hash-linked, signed audit chain. The intelligence, the model, the agent loop, the tools, lives entirely in user-space capsules; the kernel itself holds no model and no business logic. It routes events and enforces boundaries.

The payoff is one line: **you can run an agent you do not trust**, because a jailbreak, a poisoned tool, or a plain bug still cannot reach anything you did not grant, and you can prove afterward exactly what ran.

## What this book is

This is the canonical reference. It explains the whole system in depth, grounded in real code with file and line anchors, and it separates what is shipped and tested from what is planned or stubbed. The register is dry and technical on purpose: when a function is a stub, the book says so; when a path has no production caller, the book says so. Where the front-door documentation teaches and persuades, this is the text you cite when you need to know exactly how a thing works.

## How to read it

**If you want to see it run,** start with [Getting Started](getting-started/see-it-work.md). A few minutes, install to a working agent.

**If you are writing a capsule,** read Part II (The Capsule Model) and Part III (The Host ABI). That is the contract you build against.

**If you are reasoning about trust,** read Part V (Security): the capability model, the five-layer gate, and the audit chain.

**If you are about to change a contract surface,** read Part IX (Evolution) and the RFC process before you touch a line.

The parts are ordered so each builds on the last, and each also stands alone.

**If you want the argument for why Astrid is shaped this way,** the long version is the [Afterword](afterword/the-labyrinth.md). It is optional, and the machinery in between does not depend on it.
