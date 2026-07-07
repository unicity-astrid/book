# The Lineage

> "Not only is UNIX dead, it's starting to smell really bad."
>
> Rob Pike, 1991

This chapter is optional, and nothing in the reference depends on it. [The Labyrinth](./the-labyrinth.md) made the argument for Astrid's shape from fiction. This one makes it from history, because the machinery in this book is not a new idea. It is a restoration. The shape was designed twice before, at Bell Labs, by the group that built Unix, and both times it was right, and both times it died. What killed it was not a flaw in the idea. It was two missing preconditions, and both have now arrived.

## The second Unix

By the late nineteen-eighties, the people who made Unix considered it finished, and not in the flattering sense. Their answer was Plan 9: a second operating system from the same research center, with Ken Thompson among the hands and Dennis Ritchie running the department.

Plan 9 took the oldest Unix slogan, everything is a file, and made it true. The network stack is a file tree. The window system is a file tree. The process table is a file tree. Every resource in the system is served over one protocol, 9P, and because a file tree does not care which machine serves it, the system was distributed by construction rather than by afterthought. A driver, in Plan 9, is not privileged code welded into the kernel. It is just a program that serves a file tree. When someone says drivers do not need to exist, this is the sentence they are remembering.

Then the radical move. Every process gets its own private namespace: its own view of the world, composed by binding and mounting resources into it. There is no global filesystem, there is only your view. Authority is not a bit in a table somewhere. Authority is the shape of the world you were given. A process cannot open what its namespace does not contain, because it cannot even name it.

A reader of this book has seen all of this before. The private view is [per-principal isolation](../identity/principal-and-isolation.md). Composing a world out of mounted resources is [import resolution](../capsule-model/imports-exports-resolution.md). A driver as an unprivileged server is a capsule [exporting tools over the bus](../bus/tools-as-ipc.md). The absence of ambient authority is the ground rule of the entire [capability system](../security/capabilities-and-tokens.md).

Astrid makes one upgrade, and it matters. A Plan 9 namespace was enforced by a kernel you administered; the authority claim was rooted in trusting the machine, which was fine when every machine belonged to one institution. An Astrid capability is a signed token. The claim carries its own proof, so it survives delegation across parties that do not trust each other, and a child can only ever be granted less than its parent held. Namespaces enforced by trust become capabilities enforced by cryptography.

## The operating system in a browser tab

In 1996 the same group distilled the design again, for a networked world, and called it Inferno.

Programs compile to portable bytecode for a virtual machine called Dis and run identically on every machine. Resources are still file trees, served over a protocol called Styx. And the operating system itself has two modes: native, on bare metal, or hosted, running as an ordinary application on Windows or Unix. There was a build that ran the complete operating system as an Internet Explorer plugin. A full OS, with its own processes, namespaces, and network model, inside a browser tab, in 1997.

If that sounds familiar, it is because Astrid does the same trick with better materials. Capsules compile to WebAssembly and [run identically everywhere](../distribution/build-pipeline.md). The kernel runs as a daemon on your machine, or hosted inside a process that wants an operating system as a component, including a web page. Inferno is the ancestor of the claim that an OS can be something you embed, not only something you install beneath everything else. Its language, Limbo, with typed channels for concurrency, is a direct ancestor of Go. Its bet was that the unit of software is a small portable module, safe by construction, moving between machines that share nothing but a protocol.

## Why they died

Not because they were wrong.

Plan 9 was better than Unix, but it was competing with a Unix that was free and already everywhere, and it stayed under a restrictive license until the fight was over. By the time it was freely available, Linux had inherited the earth. Inferno's bet needed the whole industry to adopt one portable execution format, and the industry did adopt one, but Sun spent billions making sure it was Java's, while Inferno's owner barely showed up. Dis and Limbo remained an ecosystem of one building. Every program had to be rewritten in a language only that building spoke.

So the integrated design never shipped, and the organs were harvested one by one. Linux namespaces, the isolation machinery underneath every Linux container, are Plan 9's namespaces transplanted. Limbo's channels became Go's channels. 9P ships today inside WSL and QEMU. UTF-8 was designed for Plan 9, by Thompson and Pike, in September 1992, on a placemat in a New Jersey diner. The industry took every piece and declined the architecture.

## What changed

Two preconditions, thirty years late.

The first is the substrate. WebAssembly is the Dis that won: vendor-neutral, resident in every browser, with every serious language compiling to it, standardized by the same body that standardizes the web. But portability is the smaller half of it. The deeper property is that WASM's import model is a capability model. A module can only call what was explicitly handed to it at instantiation; it cannot even name anything else. There is no ambient syscall surface to reach for. Inferno had to discipline its virtual machine with namespaces built around it. A WASM module is born unable, and [the syscall surface](../host-abi/the-syscall-surface.md) it does receive is [gated capability by capability](../host-abi/capability-gating.md). Where Styx gave resources a common wire shape, [WIT contracts](../evolution/wit-contracts.md) give them typed, versioned, checkable interfaces. The execution format the idea always needed now exists, and Astrid did not have to build the VM, the language, or the ecosystem. Only the operating system.

The second is the tenant. Unix's tenant was a program written by a person; when it misbehaved, there was a bug to patch and an author to hold responsible. Plan 9 and Inferno were built for that same tenant, and that tenant never needed them badly enough to move. The new tenant is an agent: a mind that can be argued into things, whose misbehavior is not a defect you can patch out, because [the vulnerability to persuasion is constitutive](./the-labyrinth.md). For the first time there is a workload that cannot be run responsibly on ambient authority at all. The architecture finally has the tenant it was designed for.

Plan 9 was an answer waiting for its question. The question arrived speaking natural language.

## The restoration

The Labyrinth argued from fiction that safety must live in the walls, not in the mind. History makes the same argument from the other direction: the walls were designed twice, correctly, by the best systems programmers alive, and the world declined them, because there was no common substrate to carry the modules and no tenant that could not live without the isolation. Both preconditions arrived within a few years of each other. Astrid is not a novel idea. It is an inherited one, restored, with the missing pieces finally underneath it.
