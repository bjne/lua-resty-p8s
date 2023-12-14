local data = require "resty.p8s.data"
local merge = require "resty.p8s.merge"
local format = require "resty.p8s.format"

local ngx = ngx
local get_phase = ngx.get_phase
local shdict
local default_dict = "lua_resty_p8s"
local sync_interval, timer_started = 1


local _M do
    local metrics = {
        gauge = data.gauge,
        counter = data.counter,
        histogram = data.histogram
    }

    _M = setmetatable({}, {
        __call = function()
            ngx.header.content_type = "text/plain; version=0.0.4"
            ngx.say(format(merge(shdict)))
        end,
        __index = function(t,k)
            if shdict and not timer_started and get_phase() ~= "init" then
                timer_started = data.start_timer(shdict, sync_interval)
                if timer_started then
                    for name,metric in pairs(metrics) do
                        t[name] = metric
                    end
                end
            end

            return metrics[k]
        end
    })
end

_M.init = function(interval, dict)
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
