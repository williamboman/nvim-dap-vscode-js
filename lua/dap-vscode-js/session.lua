local M = {}
local utils = require("dap-vscode-js.utils")
local dap_breakpoints = require("dap.breakpoints")
local dap = require("dap")
local dap_utils = require("dap.utils")
local dap_bp_ns = "dap_breakpoints"

local sessions = {}

local breakpoints = {}

local root_ports = {}

function M.register_port(port)
	root_ports[port] = true
end

function M.unregister_port(port)
	root_ports[port] = false
end

function M.register_session(session, parent, proc)
	dap.set_session(session)

	sessions[session] = {
		parent = parent,
		pid = proc.pid,
		exit = proc.exit,
	}
end

function M.unregister_session(session)
	local session_info = sessions[session]

	if not session_info then
		return
	end

	if #vim.tbl_filter(function(data)
		return data.pid == session_info.pid
	end, sessions) <= 1 then
		session_info.exit()
	end

	if session_info.parent and sessions[session_info.parent] then
		dap.set_session(session_info.parent)
	end

	sessions[session] = nil
end

local function get_breakpoints(pid)
	breakpoints[pid] = breakpoints[pid] or {}
	return breakpoints[pid]
end

local function register_listener(time, key, plugin_id, func)
	dap.listeners[time][key][plugin_id] = function(session, ...)
		if not sessions[session] then
			return
		end

		func(session, sessions[session], ...)
	end
end

function M.setup_hooks(plugin_id, config)
	for _, evt in ipairs({ "event_terminated", "event_exited" }) do
		register_listener("after", evt, plugin_id, function(session)
			M.unregister_session(session)
			M.unregister_port(session.adapter.port)
		end)
	end

	dap.listeners.before["setBreakpoints"][plugin_id .. "-root"] = function(session, err, body, request)
		if err then
			return
		end

		if not root_ports[session.adapter.port] then
			return
		end

		for _, bp in ipairs(body.breakpoints) do
			bp.verified = true
		end
	end

	register_listener("before", "setBreakpoints", plugin_id, function(session, info, err, body, request)
		if err then
			return
		end

		local pid_bps = get_breakpoints(info.pid)

		for _, bp in ipairs(body.breakpoints) do
			bp.verified = true

			local unique = true

			for _, xbp in ipairs(pid_bps) do
				if xbp.id == bp.id then
					unique = false
				end
			end

			if unique then
				table.insert(pid_bps, bp)
			end
		end
	end)

	register_listener("before", "event_continued", plugin_id, function(session, info, body)
		for _, bp in ipairs(get_breakpoints(info.pid)) do
			if bp.__verified == false then
				local bp_info = utils.dap_breakpoint_by_state(bp)

				if bp_info then
					dap_breakpoints.set_state(bp_info.bufnr, bp_info.line, bp)
				end

				if bp.message then
					dap_utils.notify("Breakpoint rejected: " .. bp.message, vim.log.levels.ERROR)
				end

				bp.__verified = nil
			end
		end
	end)

	register_listener("before", "event_breakpoint", plugin_id, function(session, info, body)
		if body.reason ~= "changed" then
			return
		end

		local pid_bps = get_breakpoints(info.pid)

		local evt_bp = body.breakpoint

		if not evt_bp.id then
			return
		end

		for _, pid_bp in ipairs(pid_bps) do
			if pid_bp.id == evt_bp.id then
				pid_bp.verified = evt_bp.verified
				pid_bp.__verified = evt_bp.verified
			end
		end
	end)
end

return M
