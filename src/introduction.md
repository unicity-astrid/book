# Introduction

> "A process cannot be understood by stopping it. Understanding must move with the flow of the
> process, must join it and flow with it."
>
> Frank Herbert, *Dune*

Astrid is an operating system for AI agents. It treats an agent the way an operating system
treats a process. It boots the agent, isolates it, grants it exactly the authority it needs and
no more, and writes down everything it does in a ledger that cannot be quietly rewritten. It
does not trust the thing it is running. Because of how it is built, it does not need to.

## The labyrinth

Picture a synthetic being set loose in a labyrinth.

Inside, it moves freely. It reads, it reasons, it acts, it calls tools, it spawns children to
chase sub-problems. The walls are not there to cage it. They are there so it can run at full
speed without falling off the edge of the world. This is the first kind of safety and it points
inward: the agent can act without stopping to ask permission for every step, because the
boundaries are real and it cannot cross them by accident, by error, or by persuasion.

There is a second kind of safety and it points outward. Nothing leaves the labyrinth that the
human at the gate did not allow. And every turn the being takes is recorded on a thread that
runs behind it, a thread you cannot re-spool or fake. Tamper with a single step and the thread
shows the break.

The labyrinth is real machinery. The walls are a WebAssembly sandbox, a capability system, and a
copy-on-write filesystem where the agent's writes land in a scratch layer until a human commits
them. The thread is the audit chain: every entry signed with an ed25519 key, every entry sealing
the hash of the one before it with BLAKE3. It is Ariadne's thread with one upgrade. You cannot
cut it, tie it back, and pretend the path was unbroken. The mathematics will not let you.

Safe going in. Safe going out.

## Two ghosts in the literature

Every serious attempt to make a thinking machine safe has run into the same wall, and the
science fiction got there first.

Asimov gave his robots three laws and wrote them into the positronic brain. Then he spent a
career writing stories about how laws held inside a mind bend, deadlock, and fail under
pressure. We have the modern proof now. You can talk a language model out of its instructions. A
prompt is a suggestion, and a sufficiently clever input is a louder suggestion. Astrid does not
put the laws inside the mind. It puts them in the walls. An agent cannot write outside its
sandbox, not because it was asked nicely, but because the capability to do so was never granted,
and the host verifies a signed token before it moves a single byte. Cryptography over prompts. A
mind can be confused. A wall cannot be argued with.

Herbert went the other way. In Dune, humanity's answer to the dangerous machine mind was
prohibition. After the Butlerian Jihad it was forbidden to make a machine in the likeness of a
human mind. It is a coherent answer. It is not ours. Astrid's bet is that you do not have to
choose between a capable synthetic mind and a safe one. Build the labyrinth well enough and the
mind can be as powerful as it likes inside it, while authority stays with the human at the gate.
The agent has agency. The human has authority. Those two are not in tension. They are the two
ends of the same thread.

## Whatever comes after the model

The labyrinth does not care what kind of mind walks it.

Today the inhabitant is a large language model wrapped in an agent loop, because that is the mind
we have. Astrid makes no bet on that. The kernel holds no model, no prompt, no notion of a token
or a chat turn. A provider is a capsule. The orchestration loop is a capsule. The intelligence
lives entirely in user space. Whatever supersedes the language model, a different architecture, a
neuro-symbolic hybrid, something that does not have a name yet, inherits the same walls and the
same thread the day it can run as a capsule.

The containment is a property of the substrate, not of the paradigm. Most agent frameworks are
built around the model, so they age with it. Astrid is built around the boundary, so it does not.

## What becomes possible

Once safety is a property of the walls instead of a property of the mind, you can let the mind do
startling things.

An agent on Astrid can extend itself. It can read how a capsule is written, write one, compile
it to WebAssembly, install it, and call it, all inside the sandbox, all recorded on the thread.
An operating system whose programs can write new programs for it, under cryptographic
supervision, is a different kind of object than a chatbot. A provider is a capsule, so the same
agent runs against a hosted frontier model today and a local one tomorrow with no change above
the swap. An orchestrator is a capsule, so a debate loop, a tree-search planner, or an overnight
autonomous worker is something you write, not a framework you fork. This book is the map of that
object.

## What this book is

This is the canonical reference. It explains the whole system in depth: the kernel and its boot
sequence, the capsule model, the host ABI, the bus, the five-layer security gate, the storage and
audit layers, identity and multi-principal isolation, distribution, and the process by which the
platform itself evolves. Where the front-door documentation teaches and persuades, this book is
the text you cite when you need to know exactly how a thing works.

The register is dry and technical on purpose. Every chapter grounds its claims in real code, with
file and line anchors, and separates what is shipped and tested from what is planned or stubbed.
When a function is a stub, the book says so. When a path has no production caller, the book says
so. The labyrinth is a good metaphor precisely because the walls are real, and a reference that
romanticized them would be worse than useless.

## Who it is for, and how to read it

Engineers who want depth. Capsule authors who need the contract exactly. Contributors reasoning
about the kernel boundary. Reviewers checking a claim against the implementation.

The parts are ordered so each builds on the last, and each also stands alone. If you are writing
a capsule, start with Part II and Part III. If you are reasoning about trust, read Part V. If you
are about to change a contract surface, read Part IX and the RFC process before you touch a line.

Walk in. The thread is already running.
