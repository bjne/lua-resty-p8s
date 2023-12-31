local data = require "resty.p8s.data"

local ngx = ngx
local get_phase = ngx.get_phase
local shdict
local default_dict = "resty_p8s"
local sync_interval = 1
local timer_started

local output = data.output

local _M do
    local metrics = {
        gauge = data.gauge,
        counter = data.counter,
        histogram = data.histogram
    }

    _M = setmetatable({_VERSION = "0.3.1" }, {
        __call = function(_, ...)
            if not shdict and not ngx.shared[default_dict] then
                return nil, "shdict not available"
            end

            return output(shdict or ngx.shared[default_dict], ...)
        end,
        __index = function(t,k)
            if get_phase() ~= "init" and not timer_started then
                shdict = shdict or ngx.shared[default_dict]
                if shdict then
                    timer_started = data.start_timer(shdict, sync_interval)
                    if timer_started then
                        for name,metric in pairs(metrics) do
                            t[name] = metric
                        end
                    end
                else
                    ngx.log(ngx.CRIT, "lua_shared_dict resty_p8s not defined")
                end
            end

            return metrics[k]
        end
    })
end

_M.enable_internal_metrics = function(wid) -- true for all workers
    data.internal_metrics(true, wid)
end

_M.disable_internal_metrics = function(wid) -- true for all workers
    data.internal_metrics(false, wid)
end

_M.reset_internal_metrics = function(wid)
    data.reset_internal_metrics(wid)
end

_M.sync = function()
    if not shdict and not ngx.shared[default_dict] then
        return nil, "shdict not initialized"
    end

    return data.sync(shdict or ngx.shared[default_dict])
end

_M.init = function(a,b)
    local interval, dict

    if type(a) == "number" then
        interval, dict = a, b
    else
        interval, dict = b, a
    end

    sync_interval = tonumber(interval) or sync_interval
    if shdict then
        if data.start_timer(shdict, sync_interval) then
            return _M
        else
            return nil, "failed to start timer (for some reason)"
        end
    end

    dict = dict or default_dict

    if type(dict) ~= "table" then
        if not ngx.shared[dict] then
            error("missing lua_shared_dict: " .. tostring(dict), 2)
        end

        dict = ngx.shared[dict]
    end

    if dict.get and dict.set and dict.delete and dict.lpush and dict.rpop then
        shdict = dict

        if get_phase() ~= "init" then
            data.start_timer(shdict, sync_interval)
        end

        return _M
    end

    error("invalid shared dictionary, missing functionality", 2)
end

return _M
