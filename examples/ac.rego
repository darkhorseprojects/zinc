package agc

import rego.v1

default invoke := null

default allow := false

addressed if input.event.dm
addressed if input.event.mentioned
addressed if input.event.command

candidates contains [0, name, "explicit"] if {
	name := input.requested_policy
	name != null
	input.subject.handle in data.policies[name].callers
}

candidates contains [10, name, "channel"] if {
	input.requested_policy == null
	input.platform == "discord"
	input.resource.guild != null
	name := data.routes.channels[input.resource.channel]
}

candidates contains [20, name, "channel"] if {
	input.requested_policy == null
	input.platform == "discord"
	input.resource.guild != null
	input.resource.parent != null
	name := data.routes.channels[input.resource.parent]
}

candidates contains [30, name, "member"] if {
	input.requested_policy == null
	input.platform == "discord"
	addressed
	name := data.routes.members[input.subject.handle]
}

candidates contains [40, name, "guild"] if {
	input.requested_policy == null
	input.platform == "discord"
	input.resource.guild != null
	addressed
	name := data.routes.guilds[input.resource.guild]
}

selected := sort([candidate | some candidate in candidates])[0]

invoke := {"policy": name, "revision": data.revision, "route": selected[2], "settings": settings} if {
	name := selected[1]
	base := data.policies[name]
	not base.disabled
	input.connector in {null, base.handle}
	config := object.union(base.config, {"conversation": input.resource.conversation, "request": input.event.id})
	settings := object.union(base, {"config": config})
}

current := value if {
	value := invoke with input as input.invocation
}

same_invocation if {
	current != null
	current.policy == input.policy
	current.settings.handle == input.settings.handle
	current.settings.config == input.settings.config
	current.settings.janet == input.settings.janet
	object.subset(input.settings.limits, current.settings.limits)
}

allow if {
	same_invocation
	input.operation.kind in {"invoke", "output", "typing"}
}

allow if {
	same_invocation
	input.operation.kind == "thread"
	current.route == "channel"
}

allow if {
	same_invocation
	input.operation.kind == "import"
	current.settings.janet.imports[input.operation.provider] == true
}

allow if {
	same_invocation
	input.operation.kind == "import"
	is_object(current.settings.janet.imports[input.operation.provider])
}
