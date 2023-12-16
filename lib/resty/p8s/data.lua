local strbuf = require "string.buffer"

local sync = require "resty.p8s.sync"
local merge = require "resty.p8s.merge"
local format = require "resty.p8s.format"

local ngx = ngx
local ngx_say = ngx.say
local match = string.match
local ngx_time = ngx.time
local get_phase = ngx.get_phase
local ngx_worker_id = ngx.worker.id
local worker_cnt = ngx.worker.count()
local timer_running

local data, memo, ipc, g, c, h = {}, {}, {}
local worker_id

local _M, mt = {}, {}

local walk do
    local function walk_recurse(metric, t, depth, k, ...)
        k = k or 'null'

        if depth == 0 then
            return t, k
        end

        if not t[k] then
            metric[7] = (metric[7] or 0) + 1 -- key count
            t[k], memo.buf = {}, nil
        end

        return walk_recurse(metric, t[k], depth-1, ...)
    end

    walk = function(t, ...)
        if not t[2] then return t,3 end

        return walk_recurse(t, t, #t[2], 3, ...)
    end
end

local getname do
    local name_lookup = setmetatable({}, {__mode = "k"})

    getname = function(metric)
        if name_lookup[metric] then
            return name_lookup[metric]
        end

        for name, m in pairs(data) do
            if m == metric then
                return name
            end
        end
    end
end

local delete = function(self)
    data[self:getname()] = nil
end

local reset = function(metric, wid)
    if not worker_id then worker_id = ngx_worker_id() end
    wid = wid or worker_id

    if wid ~= true then
        if not tonumber(wid) or wid %1~=0 or wid <0 or wid>=worker_cnt then
            return metric, false
        end
    end

    if wid == true or worker_id == wid then
        metric[6] = ngx_time()
        metric[7] = 0   -- nkeys

        if metric[2] then
            metric[3] = {}
        elseif metric[1] == 3 then -- histogram
            for b=1,#metric[5]+2 do
                metric[3][b] = 0
            end
        else
            metric[3] = 0
        end

        metric[8] = 1  -- set flag to prevent merge from populating on start
    end

    for w=(wid==true and 0 or wid),(wid==true and worker_cnt-1 or wid) do
        if wid ~= worker_id then
            ipc[w] = ipc[w] or strbuf.new()
            ipc[w]:encode(getname(metric))
        end
    end

    return metric
end

local new_typ do
    local check_name = function(name)
        if not name or type(name) ~= "string" then
            return "name is required, and must be a string"
        end

        if not match(name, '^[a-zA-Z_:][a-zA-Z0-9_:]*$') then
            return "invalid metric name: " .. name
        end
    end

    local function check_label(n, label, ...)
        if n > 0 then
            if type(label) ~= "string" then
                return "label must be a string"
            elseif label == "le" then
                return "reserved label name 'le'"
            elseif not match(label, '^[a-zA-Z_][a-zA-Z0-9_]*$') then
                return "invalid metric label: " .. label
            end

            return check_label(n-1, ...)
        end
    end

    new_typ = function(typ, name, init, ...)
        local nlabels = select("#", ...)

        local err = check_name(name) or check_label(nlabels, ...)
        if err then
            return nil, err
        end

        local labels, metric = nlabels > 0 and {...}, data[name]

        local err_type = "metric with same name but different type exists"
        local err_labels = "metric with same name but different labels exists"

        if metric then
            if metric[1] ~= typ then
                return nil, err_type
            elseif type(metric[2]) ~= type(labels) then
                return nil, err_labels
            elseif labels and #metric[2] ~= #labels then
                return nil, err_labels
            elseif labels then
                for i=1,#labels do
                    if metric[2][i] ~= labels[i] then
                        return nil, err_labels
                    end
                end
            end

            -- set metatable in case this is loaded from shm
            if getmetatable(metric) == nil then
                setmetatable(metric, mt[typ])
            end

            return metric, true
        end

        data[name] = {typ, labels, labels and {} or init, nil, nil, 0, 0}
        memo.buf = nil

        return setmetatable(data[name], mt[typ])
    end
end

do
    local sync_timer = function(_, shdict)
        sync(shdict, data, memo, ipc)
    end

    _M.start_timer = function(shdict, interval)
        if not timer_running and get_phase() ~= "init" then
            merge(shdict, ngx_worker_id(), data, mt)

            timer_running = ngx.timer.every(interval, sync_timer, shdict)
        end

        return timer_tunning
    end
end

do
    local incr = function(self, l, ...)
        local n = l

        if self[2] and select('#', ...) < #self[2] then
            n = nil
        end

        if n and type(n) ~= "number" then
            n = tonumber(n)
            if not n then
                return data._c("invalid increment for %q", self:getname())
            end
        end

        local t,k = walk(self, select(n and 2 or 1, l, ...))

        t[k], self[6] = (t[k] or 0) + (n or 1), ngx_time()
    end

    mt[1] = { __index = {incr = incr }, __call = incr}

    _M.counter = function(name, ...)
        return new_typ(1, name, 0, ...)
    end
end

do
    local set = function(self, n, ...)
        n = tonumber(n)

        if not n then
            return nil, "must provide a number to gauge:set()"
        end

        local t,k = walk(self, ...)

        t[k], self[6] = n, ngx_time()
    end

    mt[2] = { __index = {set = set }, __call = set }

    _M.gauge = function(name, ...)
        return new_typ(2, name, 0, ...)
    end
end

do
    local observe = function(self, n, ...)
        n = tonumber(n)

        if not n then
            return nil, "must provide a number to histogram:observe"
        end

        local nbuckets,t,k,first_seen = #self[5]

        t,k = walk(self, ...)
        if not t[k] then
            t[k], first_seen = {}, true
        end

        t, self[6] = t[k], ngx_time()

        t[nbuckets+2] = (t[nbuckets+2] or 0) + n

        for b=nbuckets+1,1,-1 do
            if b>nbuckets or n <= self[5][b] then
                t[b] = (t[b] or 0) + 1
            elseif first_seen then
                t[b] = 0
            else
                break
            end
        end
    end

    mt[3] = { __index = {observe = observe }, __call = observe }

    local default_buckets = {0.05,0.1,0.2,0.5,1}
    local max = math.max

    _M.histogram = function(name, ...)
        local bu, offset, count, buckets = (select(1, ...)), 1
        if type(bu) == "table" then
            offset, count, buckets = 2, 0, {}
            for k,v in pairs(bu) do
                if type(k) ~= "number" or type(v) ~= "number" then
                    return nil, "le must be an array of just numbers"
                end

                count, buckets[k] = count+1, v
            end

            if count ~= #buckets then
                return nil, "invalid le agrument to histogram"
            end

            table.sort(buckets)
        else
            buckets = default_buckets
        end

        local metric, err = new_typ(3, name, {}, select(offset, ...))

        if not metric then
            return nil, err
        end

        if err == true then -- reused
            for b=max(#buckets,#metric[5]),1,-1 do
                if buckets[b] ~= metric[5][b] then
                    return nil, "histogram exists with different buckets"
                end
            end
        else
            metric[5] = buckets

            if not metric[2] then -- no labels
                for i=1,#buckets+2 do
                    metric[3][i]=0
                end
            end
        end

        return metric, err
    end
end

local set_help = function(self, help)
    self[4] = help

    return self
end

for _,m in ipairs(mt) do
    m.__index.help = set_help
    m.__index.reset = reset
    m.__index.getname = getname
    m.__index.delete = delete
end

_M.output = function(shdict)
    ngx.header.content_type = "text/plain; version=0.0.4"

    ngx_say(format(merge(shdict, worker_id or ngx_worker_id(), data)))
end

do
    local _g, _c
    local fmt = string.format
    local internal_metrics = true

    g = function(n, evt)
        if internal_metrics then
            if not _g then
                _g = _M.gauge("resty_p8s_gauge", "worker", "event")
            end

            _g(n, worker_id or ngx_worker_id(), evt)
        end
    end

    c = function(n, ...)
        if internal_metrics then
            if not _c then
                _c = _M.counter("resty_p8s_counter", "worker", "event")
            end

            if type(n) == "number" then
                return _c(n, worker_id or ngx_worker_id(), fmt(...))
            end

            _c(1, worker_id or ngx_worker_id(), fmt(n,...))
        end
    end

    _M.internal_metrics = function(enable)
        internal_metrics = enable == true
        if not internal_metrics then
            _g = _g and _g:delete()
            _c = _c and _c:delete()
        end
    end
end

setmetatable(data, {__mode = "v", __index = {_g=g,_c=c,_h=h}})


return _M
