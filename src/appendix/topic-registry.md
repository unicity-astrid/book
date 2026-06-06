# Appendix: Topic Registry

Generated from the versioned topic strings declared in capsule manifests (`capsules/*/Capsule.toml` publish and subscribe tables) and the kernel source. This lists the statically declared topics. Reply topics that capsules construct at runtime by appending a correlation id (for example `...response.<corr_id>`) are not enumerated here; see the chapter on the bus for the request and response convention.


## `agent.*`

- `agent.v1.command.sphere.*`
- `agent.v1.response`
- `agent.v1.session_changed`
- `agent.v1.stream.delta`

## `astrid.*`

- `astrid.v1.admin.*`
- `astrid.v1.admin.agent.create`
- `astrid.v1.admin.quota.set`
- `astrid.v1.admin.response.agent.create`
- `astrid.v1.admin.response.quota.set`
- `astrid.v1.approval`
- `astrid.v1.approval.response.*`
- `astrid.v1.audit.entry`
- `astrid.v1.capsules_loaded`
- `astrid.v1.elicit.*`
- `astrid.v1.elicit.response.*`
- `astrid.v1.event_bus.lagged`
- `astrid.v1.health.failed`
- `astrid.v1.lifecycle.context_compaction_completed`
- `astrid.v1.lifecycle.context_compaction_started`
- `astrid.v1.lifecycle.kernel_shutdown`
- `astrid.v1.lifecycle.kernel_started`
- `astrid.v1.lifecycle.message_received`
- `astrid.v1.lifecycle.message_sending`
- `astrid.v1.lifecycle.message_sent`
- `astrid.v1.lifecycle.session_created`
- `astrid.v1.lifecycle.session_ended`
- `astrid.v1.lifecycle.sub_agent_cancelled`
- `astrid.v1.lifecycle.sub_agent_completed`
- `astrid.v1.lifecycle.sub_agent_failed`
- `astrid.v1.lifecycle.sub_agent_spawned`
- `astrid.v1.lifecycle.tool_call_completed`
- `astrid.v1.lifecycle.tool_call_started`
- `astrid.v1.lifecycle.tool_result_persisting`
- `astrid.v1.onboarding.required`
- `astrid.v1.request.*`
- `astrid.v1.request.system`
- `astrid.v1.response.*`
- `astrid.v1.watchdog.tick`

## `cli.*`

- `cli.v1.command.execute`

## `client.*`

- `client.v1.*`
- `client.v1.connect`
- `client.v1.disconnect`
- `client.v1.heartbeat`
- `client.v1.prompt`

## `hook.*`

- `hook.v1.event.*`

## `llm.*`

- `llm.v1.request.describe`
- `llm.v1.request.generate.*`
- `llm.v1.request.generate.anthropic`
- `llm.v1.request.generate.openai`
- `llm.v1.request.generate.openai-compat`
- `llm.v1.response.describe`
- `llm.v1.response.describe.*`
- `llm.v1.stream.*`
- `llm.v1.stream.anthropic`
- `llm.v1.stream.openai`
- `llm.v1.stream.openai-compat`

## `react.*`

- `react.v1.step`

## `registry.*`

- `registry.v1.*`
- `registry.v1.active_model_changed`
- `registry.v1.get_providers`
- `registry.v1.response.*`
- `registry.v1.selection.*`
- `registry.v1.selection.callback`
- `registry.v1.set_active_model`

## `session.*`

- `session.v1.append`
- `session.v1.clear`
- `session.v1.request.*`
- `session.v1.request.clear`
- `session.v1.request.get_messages`
- `session.v1.response.*`
- `session.v1.response.clear.*`
- `session.v1.response.get_messages.*`

## `spark.*`

- `spark.v1.request.build`
- `spark.v1.response.ready`

## `sphere.*`

- `sphere.v1.channel.ready`
- `sphere.v1.contact.pair_requested`
- `sphere.v1.contact.paired`
- `sphere.v1.dm.received`
- `sphere.v1.dm.sent`
- `sphere.v1.group.joined`
- `sphere.v1.group.kicked`
- `sphere.v1.group.left`
- `sphere.v1.group.message`
- `sphere.v1.payment.received`
- `sphere.v1.payment.requested`

## `system.*`

- `system.v1.lifecycle.restart`

## `tool.*`

- `tool.v1.execute.*`
- `tool.v1.execute.*.result`
- `tool.v1.execute.create_directory`
- `tool.v1.execute.delete_file`
- `tool.v1.execute.fetch_url`
- `tool.v1.execute.grep_search`
- `tool.v1.execute.inspect_capsule`
- `tool.v1.execute.kill_process`
- `tool.v1.execute.list_capsules`
- `tool.v1.execute.list_directory`
- `tool.v1.execute.list_interfaces`
- `tool.v1.execute.list_skills`
- `tool.v1.execute.move_file`
- `tool.v1.execute.read_file`
- `tool.v1.execute.read_interface`
- `tool.v1.execute.read_process_logs`
- `tool.v1.execute.read_skill`
- `tool.v1.execute.replace_in_file`
- `tool.v1.execute.result`
- `tool.v1.execute.run_shell_command`
- `tool.v1.execute.save_identity`
- `tool.v1.execute.spawn_background_process`
- `tool.v1.execute.system_status`
- `tool.v1.execute.write_file`
- `tool.v1.request.cancel`
- `tool.v1.request.describe`
- `tool.v1.request.execute`
- `tool.v1.response.describe.*`

## `user.*`

- `user.v1.prompt`

## `users.*`

- `users.v1.context.clear.request`
- `users.v1.context.clear.response`
- `users.v1.context.get.request`
- `users.v1.context.get.response`
- `users.v1.context.list_for_user.request`
- `users.v1.context.list_for_user.response`
- `users.v1.context.list_in_context.request`
- `users.v1.context.list_in_context.response`
- `users.v1.context.set.request`
- `users.v1.context.set.response`
- `users.v1.create.request`
- `users.v1.create.response`
- `users.v1.delete.request`
- `users.v1.delete.response`
- `users.v1.get.request`
- `users.v1.get.response`
- `users.v1.link.request`
- `users.v1.link.response`
- `users.v1.links.request`
- `users.v1.links.response`
- `users.v1.list.request`
- `users.v1.list.response`
- `users.v1.resolve.request`
- `users.v1.resolve.response`
- `users.v1.set_display_name.request`
- `users.v1.set_display_name.response`
- `users.v1.set_public_key.request`
- `users.v1.set_public_key.response`
- `users.v1.unlink.request`
- `users.v1.unlink.response`

