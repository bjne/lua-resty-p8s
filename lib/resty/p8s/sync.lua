local strbuf = require "string.buffer"
local log = require "resty.p8s.log"

local ngx = ngx
local concat = table.concat
local insert = table.insert
local remove = table.remove
local sort = table.sort

local log_err = log.log_err
local log_info = log.log_info

local keep_keys = 2
local worker_id, worker_cnt

local function gauge(...)
    gauge = require("resty.p8s").gauge("p8s_sync_stats", "worker", "event")

    return gauge(...)
end

local function counter(...)
    counter = require("resty.p8s").counter("p8s_sync_events", "worker", "event")

    return counter(...)
end

local sha256_t do
    local sha256 = require "resty.sha256".new()

    local dedupe = function(t)
        local removed, count, last = 0, #t
        sort(t)

        for i=1,count do
            if i+removed > count then
                break
            elseif t[i-removed] == last then
                remove(t, i-removed)
                removed = removed + 1
            else
                last = t[i-removed]
            end
        end

        return t
    end

    sha256_t = function(t)
        sha256:reset()
        sha256:update(concat(dedupe(t)))

        return t, sha256:final()
    end
end

local function table_keys(t, keys)
    keys = keys or {}

    for k,v in pairs(t) do
        if type(k) == "string" then
            insert(keys,k)
        end

        if type(v) == "table" then
            table_keys(v, keys)
        end
    end

    gauge(#keys, worker_id, "dictionary keys")

    return keys
end

local build_options_dict = function(shdict, t)
    local keys, hash = sha256_t(table_keys(t))
    local opts = {dict=keys}
    local hash_key, list_key = worker_id .. hash, worker_id .. '_p8s_hash'

    shdict:set(hash_key, strbuf.encode(opts))
    log_info("building new dictionary")

    for _=((shdict:lpush(list_key, hash_key)) or 0),keep_keys+1,-1 do
        local hk = (shdict:rpop(list_key))
        log_info("removing dictionary key")
        if hk and hk ~= hash_key then
            shdict:delete(hk)
        end
    end

    return opts, hash
end

local new_buf = function(shdict, t)
    local opts, hash = build_options_dict(shdict, t)

    return strbuf.new(opts), hash
end

local ipcbuf = strbuf.new()

return function(shdict, data, memo, ipc)
    local buf, hash = memo and memo.buf, memo and memo.hash

    worker_id = worker_id or ngx.worker.id()
    worker_cnt = worker_cnt or ngx.worker.count()

    if not buf or not hash then
        buf, hash = new_buf(shdict, data)
    end

    if memo and not memo.buf or not hash then
        memo.buf, memo.hash = buf, hash
    end

    local serialized = buf:reset():put(hash):encode(data):get()

    gauge(#serialized, worker_id, "serialized size")

    shdict:set(worker_id, serialized)

    if ipc then
        for w=0,worker_cnt-1 do
            if w ~= worker_id and ipc[w] then
                shdict:lpush(w.."_p8s_ipc", ipc[w]:get())
                ipc[w]:reset()
            end
        end

        local key = worker_id.."_p8s_ipc"

        ipcbuf:reset()

        for _=0,(shdict:llen(key)) or 0 do
            ipcbuf:put((shdict:rpop(key)) or '')
        end

        local nevent = 0
        while #ipcbuf > 0 do
            local ok, name = pcall(ipcbuf.decode, ipcbuf)
            if not ok then
                log_err("failed to decode event: %q", name)
                break
            end

            if data[name] then
                data[name]:reset()
            end

            nevent = nevent + 1
        end

        counter(nevent, worker_id, "clear")
    end
end
