package agc

import rego.v1

default invoke := null
default allow := false

addressed if input.event.dm
addressed if input.event.mentioned
addressed if input.event.command != null
addressed if input.platform == "agent"

candidates contains [10, name, "channel"] if {
	input.platform == "discord"
	input.resource.guild != null
	name := data.routes.channels[input.resource.channel]
}
candidates contains [20, name, "channel"] if {
	input.platform == "discord"
	input.resource.guild != null
	name := data.routes.channels[input.resource.parent]
}
candidates contains [30, name, "member"] if {
	addressed
	name := data.routes.members[input.subject.handle]
}
candidates contains [40, name, "guild"] if {
	input.platform == "discord"
	input.resource.guild != null
	addressed
	name := data.routes.guilds[input.resource.guild]
}
selected := sort([candidate |
	some candidate in candidates
	input.requested_policy in {null, candidate[1]}
])[0]
invoke := {"policy": name, "revision": data.revision, "route": selected[2], "settings": base} if {
	name := selected[1]
	base := data.policies[name]
	not base.disabled
	input.connector in {null, base.handle}
}
current := value if { value := invoke with input as input.invocation }
same_invocation if {
	current != null
	current.policy == input.policy
	current.settings.handle == input.settings.handle
	current.settings.janet == input.settings.janet
	object.subset(input.settings.limits, current.settings.limits)
	base := current.settings.config
	effective := input.settings.config
	mutable := {"chat", "rerank", "summary", "rounds", "context-percent", "queue", "temporary", "path", "from", "memory", "operation", "arguments", "conversation", "request", "input", "scope"}
	object.remove(base, mutable) == object.remove(effective, mutable)
	object.get(effective, "rounds", 128) <= object.get(base, "rounds", 128)
	object.get(effective, "context-percent", 50) <= object.get(base, "context-percent", 50)
	object.remove(object.get(base, "summary", {}), {"model", "thinking"}) == object.remove(object.get(effective, "summary", {}), {"model", "thinking"})
	object.get(effective, "conversation", input.invocation.resource.conversation) == input.invocation.resource.conversation
	object.get(effective, "request", input.invocation.event.id) == input.invocation.event.id
	source := input.invocation
	scope := {"authority": input.policy, "connector": source.connector, "conversation": source.resource.conversation}
	actual := object.get(effective, "scope", scope)
	every key, value in scope { object.get(actual, key, null) == value }
}
allow if { same_invocation; input.operation.kind in {"invoke", "append", "position", "configure", "output", "typing"} }
allow if { same_invocation; input.operation.kind == "history"; input.operation.channel == input.invocation.resource.channel }
allow if { same_invocation; input.operation.kind == "thread"; current.route == "channel" }
allow if {
	same_invocation
	input.operation.kind == "import"
	grant := current.settings.imports[input.operation.provider]
	grant != false
	grant == input.settings.imports[input.operation.provider]
}
