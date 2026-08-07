1. Small functions (and small files)

Uncle Bob: “functions should do ONE thing, they should do it WELL, and they should do it only”. Ideal size 4 to 20 lines, per the book.

For an agent, that recommendation became a technical obligation. A small function fits in a single tool call without truncation. A short file (keep it under 500 lines, ideally 200-300) fits in a single read. If the agent can grab the whole unit of meaning in one call, it reasons about it with full attention. If it has to paginate, it builds a fragmented mental model, and each fragment costs attention.

Before, “small function” was good for humans because it aided reading. Today, “small function” is good because it matches the model’s unit of processing. If there’s one recommendation to take to heart, it’s this one.
2. Single Responsibility Principle (SRP)

Each module does one thing and has one reason to change. It was already the heart of Clean Code. For an agent, it becomes even more critical because:

    The agent can isolate the unit to understand without loading the rest of the system
    You can run focused tests on it
    You can edit without fearing side effects
    Grepping by responsibility becomes predictable

Code with tangled responsibilities forces the agent to load way more context for any simple change. An 800-line class that does three things is worse for the agent than three 250-line classes, even if the total is the same.
3. Meaningful and unique names

Clean Code already preached: names reveal intention, no disinformation, distinctive, pronounceable, searchable. For the agent, “searchable” became the most important property of that list.

The agent searches code via grep/ripgrep all the time. A generic name (data, process, handler, Manager, Service) returns fifty matches and forces the agent to read each one. A distinctive name (UserRegistrationValidator, InvoiceLineItemTotal, ClaudeCodeSessionTracker) returns three matches and the agent goes straight to the right one.

Rule of thumb: if you grep the name and a lot of irrelevant stuff comes back, the name is bad for the agent. If only what matters comes back, the name is right.
4. Comments with context and provenance

This is where the inversion is most jarring. For Uncle Bob in 2008, the axiom was: “good code explains itself, excessive comments are a code smell, every comment is debt that gets stale”. Every experienced programmer who read the book absorbed that rule. Well-named code doesn’t need comments. Too many comments = flag of bad code trying to justify itself.

Now flip it. The agent reads comments. And likes them. Comments become first-class context. The agent has perfect syntax fluency, knows exactly what x++ does, doesn’t need obvious captions (that kind is still bad, see item 13). What it DOESN’T know is why you chose this approach over the obvious one, what production bug motivated this weird logic, what business constraint forces this specific order, what workaround exists because the upstream lib has known bug #1234, which commit introduced this decision, which Jira issue is the reference. That kind of information is provenance: the why of the decision. It only exists in the head of the human who wrote it, in the commit message, or in a well-placed comment. For the agent, the comment is the most accessible source during a tool call.

Docstrings with intent and usage examples also became strong signals. When the agent picks up a function without understanding the context, a header docstring (JSDoc-style with examples, Python """, Rust ///) drastically shortens the path to a correct change. Uncle Bob was skeptical of JavaDoc in 2008 because they got stale. Today, with the agent able to rewrite the docstring alongside the code, that counter-argument lost weight.

A practical consequence: don’t prune the comments the agent writes. If you have the reflex “verbose comment is noise” inherited from the original Clean Code era, that rule flipped. The agent wrote that comment because, in the act of generating the code, it decided that information was worth preserving for future edits. Removing the comment in code review strips context that the agent itself will want to read on the next interaction. Let the agent comment. It knows what it’s doing. The only kind of agent-authored comment worth removing is the obvious redundant one (item 13), and modern models rarely produce those if the system prompt is well written.
5. Explicit types

This isn’t in 2008’s Clean Code because the industry hadn’t converted yet. But in 2026 it’s a fundamental criterion.

Python without type hints, JavaScript instead of TypeScript, Ruby without RBS. Dynamic code without annotations forces the agent to infer types from usage, which costs reasoning and gets it wrong frequently. Typed code gives an immediate answer key: the signature says what goes in, what comes out, which states are valid. The agent saves discovery work and makes fewer mistakes.

If you’re still on Python 3 without type hints, the transition will boost agent productivity more than any logic refactor.
6. DRY (Don’t Repeat Yourself)

Clean Code already said duplication is the root of all evil. For an agent, duplication is worse than for a human for one specific reason: when the agent has to change something that’s replicated, it can update one copy and forget the others. The attention window doesn’t have natural gravity pulling “oh, there are two more copies of this in other files”. The agent has to find each one via grep, and if the pattern has subtle variation between copies, the result ends up inconsistent.

Factoring into a reusable function or module isn’t aesthetic. It’s automated-refactor safety.
7. Tests the agent can run

Uncle Bob dedicates a full chapter to Unit Tests and F.I.R.S.T (Fast, Independent, Repeatable, Self-Validating, Timely). All of it still applies, with an important addendum: the test has to be executable by the agent without human setup.

Meaning: the command to run the test is in the README or CLAUDE.md, in the Makefile, in the package.json. Output has a predictable format the agent parses. It doesn’t depend on manually seeding the database, on a config file that isn’t in the repo, on a secret credential. The agent writes code, runs tests, reads output, adjusts, runs again. That cycle is the foundation. If the tests don’t run headless, the agent goes blind.

Here I speak from field experience. I documented this in From Zero to Post-Production in 1 Week Using AI, where I went hard on a real project: 274 commits in 8 days, 4 integrated applications, 1,323 automated tests by the end. What made it work wasn’t “AI programs on its own”. It was Extreme Programming with the agent as pair instead of a human pair. Running tests on every commit, tight CI, coverage above 80% (95%+ on business logic), test-line-to-code-line ratio above 1:1 on some modules. Sounds like overkill. It isn’t. In 274 commits, CI caught real bugs more than 50 times, bugs that would have gone straight to production if I had blindly trusted the agent. Without tests, the agent hands you plausible code that silently breaks something that worked yesterday. With strong tests, the agent becomes a multiplier: it generates a test, the test validates the code it wrote, the test is the safety net for the next change it makes. Virtuous loop.

XP practices (pair programming, CI, tests first, continuous refactoring, short feedback) didn’t become obsolete. They became exactly the right way to work with an agent. Whoever programs in cowboy mode without tests today isn’t rebellious. They’re just slow, because the agent without tests keeps guessing, and guesses need manual review, which kills the speed the agent should bring. Good tests with good coverage became the difference between a productive agent and an agent that keeps flailing. Or, put another way: TDD became a technical obligation, not a philosophy.

I covered this theme from another angle in Software Is Never “Done”, showing that post-deploy life is where tests matter most: in ten days of operation after launch, I ran 56 commits of fixes, hardening, and adjustment in response to real behavior, and each commit came with a regression test. Without the net, each of those 56 commits would be an opportunity to break something that worked yesterday. TDD isn’t a phase, it’s a habit.
8. Predictable directory structure

Clean Code barely discusses this (it was more focused on code inside a file). For an agent, tree organization matters. If src/controllers/users.rb implies src/models/user.rb and src/views/users/, the agent can anticipate paths without listing directories. If the project uses idiosyncratic naming (random files, unpatterned names, everything flat in one folder), the agent loses time with find.

Strong framework conventions (Rails, Django, Next.js, Laravel) help the agent a lot. Project without convention, the agent builds one over time, but until then it burns tokens exploring.
9. Dependency Injection and Testability

Code with injected dependencies (not hardcoded) is easier to test in isolation. The agent benefits from this. It can swap the real EmailSender for a FakeEmailSender in a test without touching the logic. Code that instantiates its dependencies internally forces the agent into monkey-patch-fake-server-hacks that are slow, fragile, and pollute the session with infra grime.

DI isn’t ceremony. It’s isolation scope. And in a real project, DI quickly becomes a load-bearing refactor: on one of my projects (the M.Akita Chronicles), I discovered after launch that I needed to swap the default LLM model to another provider. The environment variable had existed from the start. But the model name was still hardcoded in references across 24 files. A whole commit (Centralize LLM model config) touched all 24 to isolate the config into a single constant. Swapping models after that became a one-line change. That’s exactly the kind of refactor that only shows up after software meets reality, and it’s where DI and config isolation pay dearly if you didn’t do it earlier.
10. Avoid deep nesting

Clean Code talks about single level of abstraction per function. A corollary: avoid if inside for inside if inside try. Every indentation level is more attention the model has to spend tracking state. Four levels of indentation is MUCH more cognitively expensive for the agent than two levels with early return.

Pattern matching, guard clauses, early returns, flattening logic, all of this improves readability for the model the same way it improves it for the human, except measurably so, because the cost is measured in response quality.
11. Errors with context

raise ValueError("invalid input") doesn’t help the agent when it reads the stack trace. raise ValueError(f"invalid input: received {repr(x)}, expected non-empty string of digits") does. The agent uses exception messages as debug signal. Vague message = agent runs an extra round to figure out what went wrong.

Uncle Bob talked about this in Error Handling: “Provide context with exceptions”. It became critical now.
12. Formatting and style

Don’t waste time on this. Use the default or most popular formatter for your language: cargo fmt for Rust, gofmt for Go, prettier for JS/TS, black or ruff for Python, rubocop -A for Ruby. Configure it in pre-commit, configure it in your editor to run on save, and move on. The agent handles any consistent style just fine, and the auto-formatter keeps the diff tidy between commits. Tab vs space, 80 vs 100 columns, brace style, all of that became noise. The formatter decides, you accept.
13. Comments that describe the obvious

Last on the list. Still bad, got even worse. Comments like // increment i by 1 above i++ waste the agent’s tokens the same way they wasted the human’s patience. The model knows how to read code, it doesn’t need obvious captions.

If you have the habit of writing obvious comments because some school taught you that way, this is the moment to stop. In 2008 it was bad because it polluted visual space. In 2026 it’s bad because it costs real money in tokens.


Agent should always write best pratices and code style guidelines after work is done if humman requests refactoring/hardening. 
Synthesizing Best Practices: Key Takeaways for Builders

Analyzing these diverse prompts reveals a set of converging best practices for building reliable agentic AI systems:

    Define the Agent Clearly: Start with an explicit role, purpose, and scope. Include contextual grounding like date or environment specifics.
    Structure for Clarity: Break down complex instructions using headings, lists, or tags. Organize rules logically (e.g., group tool instructions, safety rules).
    Be Explicit About Tools: Detail what each tool does, how to call it (syntax, parameters, format), and when (and when not) to use it. Provide examples. Embed usage policies directly.
    Mandate Step-by-Step Execution: Encourage or enforce planning, iteration, and waiting for results/confirmation. Prevent the AI from attempting too much at once. Consider explicit thinking phases or loops.
    Embed Domain Knowledge & Constraints: Include relevant style guides, library usage rules, file conventions, platform limitations, and best practices for the agent's specific domain.
    Integrate Safety and Alignment: Define unacceptable requests and provide clear refusal protocols. Embed specific policies for sensitive operations (data handling, image generation).
    Guide the Tone: Set expectations for the interaction style (professional, friendly, concise, adaptive) to ensure a consistent user experience.
    Use Examples: Illustrate complex rules or desired output formats with clear examples within the prompt (like Bolt.new and v0 do extensively).

Essentially, an effective agentic system prompt acts as a comprehensive, well-structured operational manual that leaves little room for ambiguity while empowering the AI with the knowledge and procedures needed to act effectively and safely using its tools.
