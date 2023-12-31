local strbuf = require "string.buffer"

local ngx = ngx
local max = math.max
local sub = string.sub
local remove = table.remove

local worker_cnt = ngx.worker.count()

local typ_counter, typ_gauge, typ_histogram = 1,2,3

-- 1 typ
-- 2 labels
-- 3 data
-- 4 help
-- 5 buckets
-- 6 updated
-- 7 keycount
-- 8 reset signal
-- 9 nomerge

local worker_data do
    local bufs = setmetatable({}, {__mode="v"})

    local new_buf do
        local lru = {}
        new_buf = function(shdict, worker, dict_id)
            local dict, buf = (shdict:get(worker .. dict_id))
            if dict then
                local ok, opts = pcall(strbuf.decode, dict)
                if not ok then
                    return nil, "dict decode error"
                end
                buf = strbuf.new(opts)
                bufs[dict_id] = buf
                table.insert(lru, 1, buf)
            end

            if #lru > 10 then
                remove(lru, 11)
            end

            return buf
        end
    end

    local get_buf = function(shdict, worker, dict_id)
        if bufs[dict_id] then
            return bufs[dict_id]
        end

        return new_buf(shdict, worker, dict_id)
    end

    local wd = strbuf.new()
    worker_data = function(shdict, worker, data)
        wd:reset():put((shdict:get(worker)) or '')
        if #wd > 32 then
            local buf, err = get_buf(shdict, worker, wd:get(32))

            if buf then
                buf:set(wd:ref())

                local ok, dec = pcall(buf.decode, buf)

                if ok then
                    return dec
                end

                if data._internal_metrics then
                    data._c("decode failed")
                end
            elseif err then
                if data._internal_metrics then
                    data._c("buffer error: %q", err)
                end
            else
                if data._internal_metrics then
                    data._c("failed to get dict")
                end
            end
        end
    end
end

local merge do
    local diff = function(a,b)
        for i=1,#a do if a[i]~=b[i] then return true end end
    end

    local merge_histogram = function(a, b)
        if a then
            for i=1,#a do
                a[i] = a[i] + b[i]
            end
        end

        return a or b
    end

    local merge_counter = function(a,b)
        return (a or 0) + (b or 0)
    end

    local function recurse_merge(metric, a, b, depth, f)
        for k,v in pairs(b) do
            if depth==1 then
                a[k] = f(a[k], v)
            elseif a[k] then
                recurse_merge(metric, a[k], v, depth-1, f)
            else
                metric[7] = (metric[7] or 0) + 1 -- key count
                a[k] = v
            end
        end
    end

    local merge_typ do
        merge_typ = {
            [typ_counter] = function(a,b)
                if a[2] then
                    return recurse_merge(a, a[3],b[3], #a[2], merge_counter)
                end

                a[3] = merge_counter(a[3], b[3])
            end,
            [typ_gauge] = function(a,b)
                return merge_typ[typ_counter](a,b)
            end,
            [typ_histogram] = function(a,b)
                if a[2] then
                    return recurse_merge(a, a[3], b[3], #a[2], merge_histogram)
                end

                a[3] = merge_histogram(a[3], b[3])
            end
        }
    end

    local byte = string.byte
    local find = string.find

    merge = function(a,b,data,internal_metrics,mt)
        if not b then return end
        local typ, a_data
        for name, b_data in pairs(b) do
            typ, a_data = type(b_data), a[name]

            if byte(name, 1) == 95 then
                -- intentionally empty; skip internal fields like _internal_metrics
            elseif not a_data then
                b_data[8] = nil -- do not accept reset from other workers
                if not internal_metrics and find(name, '^resty_p8s_') then
                    -- intentionally empty; skip merging internal metrics
                elseif data[name] and data[name][9] then -- nomerge
                    if b == data then
                        a[name] = b_data -- merge from self
                    end
                else
                    a[name] = mt and setmetatable(b_data, mt[b_data[1]]) or b_data
                end
            elseif typ ~= type(a_data) then
                if data._internal_metrics then
                    data._c("multiple types for metric")
                end
            elseif typ ~= "table" then
                if data._internal_metrics then
                    data._c("unsupported metric value")
                end
            elseif b_data[1] ~= a_data[1] then
                if data._internal_metrics then
                    data._c("multiple metric definitions")
                end
            elseif type(b_data[2]) ~= type(a_data[2]) then
                if data._internal_metrics then
                    data._c("labeled and unlabeled metric")
                end
            elseif b_data[1] <= typ_gauge and b_data[2] == nil then
                a_data[3] = (a_data[3] or 0) + (b_data[3] or 0)
            elseif b_data[2] and #b_data[2] ~= #a_data[2] then
                if data._internal_metrics then
                    data._c("inconsistent label numbers")
                end
            elseif b_data[2] and diff(a_data[2], b_data[2]) then
                if data._internal_metrics then
                    data._c("inconsistent label names")
                end
            elseif b_data[1] >= typ_histogram and diff(b_data[5],a_data[5]) then
                if data._internal_metrics then
                    data._c("inconsistent bucket values")
                end
            elseif a_data[8] == 1 then -- local reset flag
                a_data[8] = nil
            else
                a_data[6] = max(a_data[6] or 0, b_data[6] or 0) -- last updated
                merge_typ[b_data[1]](a_data, b_data)
            end
        end
    end
end

return function(shdict, worker, data, internal_metrics, mt)
    if mt then -- local startup merge from shm
        return merge(data, worker_data(shdict, worker, data), data, true, mt)
    end

    local merged = {}

    --[[
        iterate one extra time, and merge (current) local data last to prevent
        the internal data structure from beeing mangled by a merge
    --]]
    for wid=0, worker_cnt do
        if wid==worker_cnt then
            merge(merged, data, data, internal_metrics) -- final merge
        elseif wid~=worker then
            merge(merged, worker_data(shdict, wid, data), data, internal_metrics)
        end
    end

    return merged
end
