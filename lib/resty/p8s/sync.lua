local strbuf = require "string.buffer"

local ngx = ngx
local concat = table.concat
local insert = table.insert
local remove = table.remove
local sort = table.sort

local keep_keys = 2
local worker_id
local worker_cnt = ngx.worker.count() -- available in init_by_lua

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
        t = dedupe(t)

        sha256:reset()
        sha256:update(concat(t))

        return t, sha256:final()
    end
end

local function table_keys(t, keys)
    keys = keys or {}

    for k,v in pairs(t) do
        if type(k) == "string" and #k > 2 then
            insert(keys,k)
        end

        if type(v) == "table" then
            table_keys(v, keys)
        end
    end

    return keys
end

local build_options_dict = function(shdict, data)
    local keys, hash = sha256_t(table_keys(data))

    local opts = {dict=keys}
    local hash_key, list_key = worker_id .. hash, worker_id .. '_p8s_hash'

    local serialized_opts = strbuf.encode(opts)

    if data._internal_metrics then
        data._g(#keys, "dict keys")
        data._g(#serialized_opts, "dict size")
    end

    shdict:set(hash_key, serialized_opts)

    if data._internal_metrics then
        data._c("build dict")
    end

    for _=((shdict:lpush(list_key, hash_key)) or 0),keep_keys+1,-1 do
        local hk = (shdict:rpop(list_key))
        if data._internal_metrics then
            data._c("remove dict")
        end

        if hk and hk ~= hash_key then
            shdict:delete(hk)
        end
    end

    return opts, hash
end

local new_buf = function(shdict, data)
    local opts, hash = build_options_dict(shdict, data)

    return strbuf.new(opts), hash
end

local ipcbuf = strbuf.new()
local ipc_key_suffix, ipc_key = "_p8s_ipc"

return function(shdict, data, memo, ipc)
    if not worker_id then
        worker_id = ngx.worker.id()
        ipc_key = worker_id .. ipc_key_suffix
    end

    -- repeat is only done when internal_metric keys are added
    local enc, siz repeat
        local buf, hash = memo and memo.buf, memo and memo.hash

        siz = enc and #enc

        if memo and memo.rebuild then
            buf, hash, memo.rebuild = nil, nil, nil
        end

        if not buf or not hash then
            buf, hash = new_buf(shdict, data)
            memo.buf, memo.hash = buf, hash
        end

        enc = buf:reset():put(hash):encode(data):get()

        if data._internal_metrics then
            data._g(#enc, "data size")
        end
    until not memo.rebuild and (not siz or siz==#enc)

    shdict:set(worker_id, enc)

    if ipc then
        for worker=0,worker_cnt-1 do
            if worker ~= worker_id and ipc[worker] then
                shdict:lpush(worker .. ipc_key_suffix, ipc[worker]:get())
                ipc[worker]:reset()
            end
        end

        ipcbuf:reset()

        for _=0,(shdict:llen(ipc_key)) or 0 do
            ipcbuf:put((shdict:rpop(ipc_key)) or '')
        end

        local nevent = 0
        while #ipcbuf > 0 do
            local ok, msg = pcall(ipcbuf.decode, ipcbuf)
            if not ok then
                if data._internal_metrics then
                    data._c("failed to decode event")
                end
                break
            end

            if type(msg) == "string" then
                if data[msg] then
                    data[msg]:reset()
                end
            elseif type(msg) == "table" then
                data._msg(msg)
            end

            nevent = nevent + 1
        end

        if nevent > 0 and data._internal_metrics then
            data._c(nevent, "ipc")
        end
    end
end
