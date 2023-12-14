local _M = {}

local ngx = ngx
local format = string.format
local ngx_log = ngx.log
local INFO, WARN, ERR = ngx.INFO, ngx.WARN, ngx.ERR

local log_level = {INFO="INFO",WARN="WARN",ERR="ERR"}

local counter, worker_id
local log_info, log_warn, log_err = true, true, true

_M.set_info = function(enable) log_info = enable == true end
_M.set_warn = function(enable) log_warn = enable == true end
_M.set_err  = function(enable) log_err  = enable == true end

local get_counter = function()
    worker_id = ngx.worker.id()
    return require("resty.p8s").counter("resty_p8s_log", "worker", "level", "msg")
end

local log = function(level, ...)
    counter = counter or get_counter()
    local msg = format(...)

    counter(1, worker_id, log_level[level], msg)

    return ngx_log(level, msg)
end

_M.log_info = function(...)
    return log_info and log(INFO, ...)
end

_M.log_warn = function(...)
    return log_warn and log(WARN, ...)
end

_M.log_err = function(...)
    return log_err and log(ERR, ...)
end

return _M
