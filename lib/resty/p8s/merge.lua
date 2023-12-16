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

    worker_data = function(shdict, worker, data)
        local wd = shdict:get(worker)
        if wd then
            local dict_id = sub(wd, 1, 32)

            local buf, err = bufs[dict_id]

            if not buf then
                buf, err = new_buf(shdict, worker, dict_id)
            end

            if buf then
                buf:reset():put(wd):skip(32)

                local ok
                ok, wd = pcall(buf.decode, buf)

                if ok then
                    return wd
                end

                data._c("decode failed")
            elseif err then
                data._c("buffer error: %q", err)
            else
                data._c("failed to get dict")
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

    merge = function(a,b,data,mt)
        if not b then return end
        local typ, a_data
        for name, b_data in pairs(b) do
            b_data[8] = nil -- do not accept reset from other workers
            typ, a_data = type(b_data), a[name]

            if not a_data then
                if data[name] and data[name][9] then -- nomerge
                    if b == data then
                        a[name] = b_data -- merge from self
                    end
                else
                    a[name] = mt and setmetatable(b_data, mt[b_data[1]]) or b_data
                end
            elseif typ ~= type(a_data) then
                data._c("multiple types for metric")
            elseif typ ~= "table" then
                data._c("unsupported metric value")
            elseif b_data[1] ~= a_data[1] then
                data._c("multiple metric definitions")
            elseif type(b_data[2]) ~= type(a_data[2]) then
                data._c("labeled and unlabeled metric")
            elseif b_data[1] <= typ_gauge and b_data[2] == nil then
                a_data[3] = (a_data[3] or 0) + (b_data[3] or 0)
            elseif b_data[2] and #b_data[2] ~= #a_data[2] then
                data._c("inconsistent label numbers")
            elseif b_data[2] and diff(a_data[2], b_data[2]) then
                data._c("inconsistent label names")
            elseif b_data[1] >= typ_histogram and diff(b_data[5],a_data[5]) then
                data._c("inconsistent bucket values")
            elseif a_data[8] == 1 then -- local reset flag
                a_data[8] = nil
            else
                a_data[6] = max(a_data[6] or 0, b_data[6] or 0) -- last updated
                merge_typ[b_data[1]](a_data, b_data)
            end
        end
    end
end

return function(shdict, worker, data, mt)
    if mt then -- local startup merge from shm
        return merge(data, worker_data(shdict, worker, data), data, mt)
    end

    local merged = {}

    --[[
        iterate one extra time, and merge (current) local data last to prevent
        the internal data structure from beeing mangled by a merge
    --]]
    for wid=0, worker_cnt do
        if wid==worker_cnt then
            ngx.log(ngx.ERR, "FINAL MERGE")
            merge(merged, data, data) -- final merge, no risk of data corruption
        elseif wid~=worker then
            merge(merged, worker_data(shdict, wid, data), data)
        end
    end

    return merged
end
