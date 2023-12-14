local strbuf = require "string.buffer"
local log = require "resty.p8s.log"

local ngx = ngx
local max = math.max
local sub = string.sub
local worker_count = ngx.worker.count
local log_warn = log.log_warn
local log_err = log.log_err

local typ_counter, typ_gauge, typ_histogram = 1,2,3

-- 1 typ
-- 2 labels
-- 3 data
-- 4 help
-- 5 buckets
-- 6 updated
-- 7 keycount

local worker_data do
    local bufs = setmetatable({}, {__mode="v"})

    local new_buf do
        local lru = {}
        new_buf = function(shdict, worker, dict_id)
            local dict, buf = (shdict:get(worker .. dict_id))
            if dict then
                local ok, opts = pcall(strbuf.decode, dict)
                if not ok then
                    log_err("failed to decode dictionary")

                    return
                end
                buf = strbuf.new(opts)
                bufs[dict_id] = buf
                table.insert(lru, 1, buf)
            end

            if #lru > 10 then
                table.remove(lru, 11)
                log_warn("recycling buffers")
            end

            return buf
        end
    end

    worker_data = function(shdict, worker)
        local data = shdict:get(worker)
        if not data then
            return true
        end

        local dict_id = sub(data, 1, 32)
        local buf = bufs[dict_id] or new_buf(shdict, worker, dict_id)

        if not buf then
            log_err("failed to get dictionary from worker: %d", worker)

            return true
        end

        buf:reset():put(data):skip(32)

        local ok, wd = pcall(buf.decode, buf)

        if ok then
            return wd
        end

        log_err("failed to decode: %q", wd)
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

    merge = function(a,b,mt)
        if not b then return end
        for name, b_data in pairs(b) do
            b_data[8] = nil -- do not accept clear from other workers or...
            local typ, a_data = type(b_data), a[name]
            if not a_data then
                a[name] = mt and setmetatable(b_data, mt[b_data[1]]) or b_data
            elseif typ ~= type(a_data) then
                log_err("multiple types for metric: %s", name)
            elseif typ ~= "table" then
                log_err("unsupported metric value: %s", typ)
            elseif b_data[1] ~= a_data[1] then
                log_err("multiple metric definitions: %s", name)
            elseif type(b_data[2]) ~= type(a_data[2]) then
                log_err("labeled and unlabeled metric: %s", name)
            elseif b_data[1] <= typ_gauge and b_data[2] == nil then
                a_data[3] = (a_data[3] or 0) + (b_data[3] or 0)
            elseif b_data[2] and #b_data[2] ~= #a_data[2] then
                log_err("inconsistent label numbers: %s", name)
            elseif b_data[2] and diff(a_data[2], b_data[2]) then
                log_err("inconsistent label names: %s", name)
            elseif b_data[1] >= typ_histogram and diff(b_data[5],a_data[5]) then
                log_err("inconsistent bucket values: %s", name)
            elseif a_data[8] == 1 then -- local clear flag
                a_data[8] = nil
            else
                a_data[6] = max(a_data[6] or 0, b_data[6] or 0) -- last updated
                merge_typ[b_data[1]](a_data, b_data)
            end
        end
    end

end

return function(shdict, worker, data, mt)
    data = data or {}

    for wid=(worker or 0), (worker or (worker_count()-1)) do
        local wd = worker_data(shdict, wid, worker and mt)
        if wd and wd ~= true then
            merge(data, wd, mt)
        elseif not wd then
            log_err("failed to decode data for worker: %d", wid)
        end
    end

    return data
end
