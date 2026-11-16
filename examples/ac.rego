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
	input.resource.parent != null
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

command_config := {"operation": "submit"} if {
	input.event.command == null
}

command_config := object.union(overrides, {"operation": "submit"}) if {
	input.event.command.name == "agent"
	args := input.event.command.arguments
	allowed := {"prompt", "policy", "chat", "thinking", "rounds", "queue", "path", "from", "memory", "temporary"}
	count(object.keys(args) - allowed) == 0
	overrides := object.filter(args, {"chat", "thinking", "rounds", "queue", "path", "from", "memory", "temporary"})
}

command_config := {"operation": name, "arguments": args} if {
	name := input.event.command.name
	args := input.event.command.arguments
	allowed := {
		"reset": set(),
		"models": {"role"},
		"world-point": set(),
		"world-view": {"reference"},
		"world-inspect": {"reference"},
		"memory-expand": {"reference"},
	}
	count(object.keys(args) - allowed[name]) == 0
}

invoke := {"policy": name, "revision": data.revision, "route": selected[2], "settings": settings} if {
	name := selected[1]
	base := data.policies[name]
	not base.disabled
	input.connector in {null, base.handle}
	object.get(command_config, "rounds", base.config.rounds) <= base.config.rounds
	config := object.union(
		object.union(base.config, command_config),
		{"conversation": input.resource.conversation, "request": input.event.id},
	)
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
