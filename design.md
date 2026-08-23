# Design

## Guide

### Start with the job

Begin with the practical job, not a framework. State what starts the agent, what input it receives, what useful result it must return, and who will use that result. Ask for one realistic request and its ideal response. If those cannot be stated clearly, do not create files yet.

Ask only for missing facts that change behavior, authority, failure handling, or acceptance. Summarize those decisions before implementation so the package does not quietly invent policy.

### Define the result

Describe the result precisely enough to test. Separate the answer the agent returns from intermediate reasoning, tool activity, logs, and external side effects. Decide which facts must be present, which formats or byte limits apply, and what counts as incomplete or misleading output.

### Authority

List every resource the job needs: readable and writable directories, HTTP origins, configured processes, credentials, registered host capabilities, and external services. Grant only those resources. Broad authority is acceptable when it is deliberate and visible; do not disguise an unrestricted shell or ambient credential as a narrow capability.

Identify actions that are destructive, irreversible, externally visible, expensive, or security-sensitive. State which require confirmation and what evidence the agent must present before acting. Never invent a path, token, recipient, service, or destructive action to avoid asking a necessary question.

### Markdown and Lua

Keep operator instructions, model configuration, roots, origins, command shapes, and substantial user-visible prose in Markdown. Keep reusable behavior in small Lua modules. Use ordinary Lua tables, closures, factories, coroutines, `package.path`, `require`, and `package.loaded`; do not add registries or lifecycle abstractions that duplicate the language.

Use one explicit Markdown entry. Add another source file only when it owns a distinct responsibility or removes duplication. A small package should be understandable by reading the entry and then the few modules it requires.

### Generated execution

Generated Lua receives a fresh explicit environment. Expose only the values required for the current job. Treat generated code and retrieved records as untrusted. Authoritative physical modules may use ambient system facilities and may deliberately return narrower capabilities, but generated code must not be able to discover those facilities on its own.

Registered capabilities are concrete native Lua package values. Give substantial capabilities a `guide`, discover them through `package.loaded`, and load them with native `require` only when needed.

### Results and persistence

Commit each completed request, assistant action, tool result, and response independently before exposing it as completed. Keep unfinished work absent. A later failure must not erase earlier completed work. Use one request record ID as the execution `start`; historical reads remain actor-isolated and end at `id < start`.

Nested requests are ordinary durable chronological work. Do not invent parent trees, terminal statuses, snapshots, merge/discard state, or rollback of previously completed records. A hard kill may leave the current unfinished item absent, but every earlier committed result remains.

### Failure behavior

For each external dependency, state what failure means. Tool mistakes may be returned to the model for correction. Provider, stopping, authority, persistence, and deadline failures must not be converted into successful answers. Do not add synthetic fallbacks that conceal missing evidence or broken services.

### Dependencies and platforms

Name required runtimes, native libraries, services, model files, versions, and supported operating systems. Provisioning belongs outside the running package. Pin artifacts that affect behavior and record how each dependency is verified.

### Behavioral acceptance

Test boundaries a user could actually depend on: exact authority, generated-state isolation, file and command policy, direct-process deadlines, cancellation, actor concurrency, completed-record persistence, later failure, retrieval quality, context bounds, and final delivery. Prefer real adjacent components over tests that merely reproduce a helper's branches.

### Completion checklist

Before declaring the package complete, verify:

- the trigger, request, result, and actor are explicit;
- every authority grant is necessary and visible;
- confirmation and failure behavior are written down;
- Markdown contains configurable policy and substantial prose;
- Lua files have distinct responsibilities and use native language behavior;
- every completed result is atomically stored before exposure;
- generated code receives only the intended values;
- dependencies and platforms are pinned and checked;
- behavioral tests prove the acceptance criteria;
- installation, checking, cancellation, and deadlines work in a real disposable process.

## Program

```lua
return { guide = document.Design.Guide }
```
