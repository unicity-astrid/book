# The Harvest

> "The computer revolution hasn't happened yet."
>
> Alan Kay, OOPSLA, 1997

This chapter is optional, and nothing in the reference depends on it. [The Lineage](./the-lineage.md) told the history of two operating systems from one building that reached Astrid's shape first and died waiting for their preconditions. This chapter widens the frame, because the operating system people dreamed of between the sixties and the nineties was never one dream. It was six, dreamed by communities that barely spoke to each other, killed separately, and then something stranger than killed. Eaten.

## The six dreams

The first dream was authority as an unforgeable object. Dennis and Van Horn described capabilities in 1966; Hydra built them at Carnegie Mellon; KeyKOS ran them commercially; and in 1981 Intel built them into silicon as the iAPX 432, a processor whose every memory reference was a checked capability. Authority would be something you hold, not something a table says about you.

The second was the system that knows itself. On a Lisp machine, running Genera, there was no wall between you and the operating system: every object was inspectable, every function was source, the machine was a live description of itself that you could read and reshape while it ran.

The third was software as composable parts. OpenDoc and Taligent bet that the monolithic application was a historical accident, and that documents and services should be assembled from typed components made by strangers.

The fourth was the mobile agent. General Magic's Telescript, in 1994, described small programs that travel to where the work is, carrying metered authority called permits, spending them at electronic marketplaces, teleporting home with the result. They named the agent economy three decades early.

The fifth was the reasoning system, the operating system with a mind of its own; that thread is old enough and deep enough that it gets [the next chapter](./the-namesake.md) to itself.

And beneath them all, the oldest: Licklider's man-computer symbiosis, from 1960, a partnership in which each side holds what it holds best. That one was not murdered. It starved, because there was no machine partner worth the symbiosis.

## Never of wrongness

Look at the causes of death, because the pattern is the argument.

The 432 was slaughtered by benchmarks, on hardware where every check was unaffordable; the checks it died for cost effectively nothing on the hardware in front of you. The Lisp machines died of commodity economics and an AI winter; the economics have inverted, and [a portable sandbox](../security/os-process-sandbox.md) now runs on everything. Telescript died because the open web arrived and because an agent carrying your authority onto someone else's machine was an unanswerable security question in 1994; it is precisely the question a [signed capability](../security/capabilities-and-tokens.md) answers. OpenDoc died of application-suite economics and a platform war, not of a flaw in composition. The reasoning thread died of a knowledge bottleneck the next chapter shows being deleted by construction. And symbiosis simply waited for its partner, who arrived speaking natural language.

Six deaths. Not one of wrongness. Every certificate lists the same cause: a missing precondition, since arrived.

## The harvest

Here is the stranger part, and the reason this chapter exists. The industry did not merely kill these architectures. It ate them, and the eating kept every organ alive.

Plan 9's namespaces beat inside every container on earth. Limbo's channels became Go, the language the cloud is written in; 9P ships inside WSL and QEMU; UTF-8 is simply what text is now. Unification became the type inference in every compiler; resolution became the SAT and SMT solvers that verify the chips this book is read on; Datalog quietly runs the static analyzers of ordinary industry, and the formal restatement of Rust's borrow checker is a Datalog program. Capabilities survived as fragments everywhere the stakes got real: the file descriptor, Capsicum, mobile entitlements, the process model inside every browser. Genera's living inspectability came back diminished as debuggers and developer tools. Telescript's permits came back diminished as OAuth scopes.

The eaters grew measurably stronger with every meal. And no whole body ever walked again, because a body is a competitor and an organ is just a feature.

But cannibalism preserves. This is the fact the eulogies miss. Every organ Astrid needs has been load-tested for decades, at planetary scale, in the most hostile environments computing has: billions of containers, every TLS handshake, every borrow-checked build. Nothing in this book's architecture is speculative tissue. The namespaces work. The portable bytecode won. The relational reasoning is industrially boring. The cryptography is the most battle-proven artifact the field has ever produced. The only thing that was ever actually lost was the body plan, the knowledge that these are organs of one organism.

## One body

Because that is what they were. The six dreams were partial drawings of a single machine, made by people who could not see each other's pages. The capability people did not talk to the Lisp people. General Magic did not know it needed KeyKOS. The reasoning thread did not know its knowledge bottleneck would be solved by an operating system's [interface declarations](../capsule-model/imports-exports-resolution.md). Assemble the pages and the machine appears: it takes the walls to safely house the self-knowledge, the self-knowledge to feed the reasoner, the reasoner to guide the agents, the agents composed from typed components, the components resolved across private namespaces, the whole of it in symbiosis with the person [at the gate](./the-labyrinth.md). Any one dream alone was killable, and was killed. Together they are load-bearing for each other.

One dream is deliberately left in the ground, and honesty requires naming it. Smalltalk's fully live image, the system reshaped bare-handed while it runs, is declined in its original form, because the new tenant makes unrestricted self-modification a threat model. It returns in its safe form instead: an agent that extends the system [through the verifier](../distribution/build-pipeline.md), every change signed, every generation recoverable. Kay's revolution is not denied. It is deferred to a tenant the walls can hold.

So this is not resurrection, which is the raising of dead tissue. The tissue never died. It is restoration in the older sense: walking through the industry's workshop with the original anatomy diagram, pointing at what runs the containers and the compilers and the browsers, and saying, that is ours, and that, and that.

They ate the architecture. They kept it warm. It is asking for itself back.
