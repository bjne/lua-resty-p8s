local concat = table.concat
local insert = table.insert
local format = string.format
local gsub = string.gsub

local clear_tab do local ok
    ok, clear_tab = pcall(require, "table.clear")
    if not ok then
        clear_tab=function(t) for k in pairs(t) do t[k]=nil end end
    end
end

local function recurse_action(name, metric, t, f, depth, ...)
    depth = depth or #metric[2]
    for k,v in pairs(t) do
        if depth==1 then
            f(name, metric, v, k, ...)
        else
            recurse_action(name, metric, v, f, depth-1, k, ...)
        end
    end
end

local typ_counter, typ_gauge, typ_histogram = 1,2,3

local output, format_typ = {}, setmetatable({}, {__index = function(_, k)
    return function()
        ngx.log(ngx.ERR, "undefined formatter for type: ", k)
    end
end})

local add = function(...)
    insert(output, format(...))
end

--[[
    # HELP http_requests_total Total number of http api requests
--]]

local help = function(name, metric)
    if metric[4] then
        add([[# HELP %s %s]], name, metric[4])
    end
end

--[[
    label_value can be any sequence of UTF-8 characters, but the backslash (\),
    double-quote ("), and line feed (\n) characters have to be escaped as
    \\, \", and \n, respectively.
--]]

local format_labels = function(metric, ...)
    local vals, labels, nkeys, label = {...}, {}, #metric[2]
    for i=1,nkeys do
        label = format([[%s=%q]], metric[2][i], vals[nkeys-i+1])
        labels[i] = label:gsub("\\\n", "\\n")
    end

    return labels
end

local format_counter = function(name, metric, value, ...)
    if not metric[2] then
        return add([[%s %s %s]], name, value, metric[6])
    end

    local labels = format_labels(metric, ...)
    add([[%s{%s} %s]], name, concat(labels, ','), value)
end

--[[

The histogram and summary types are difficult to represent in the text format.
The following conventions apply:

* The sample sum for a summary or histogram named x is given as a separate
  sample named x_sum.
* The sample count for a summary or histogram named x is given as a separate
  sample named x_count.
* Each quantile of a summary named x is given as a separate sample line with
  the same name x and a label {quantile="y"}.
* Each bucket count of a histogram named x is given as a separate sample line
  with the name x_bucket and a label {le="y"} (y is the bucket upper bound).
* A histogram must have a bucket with {le="+Inf"}. Its value must be identical
  to the value of x_count.
* The buckets of a histogram and the quantiles of a summary must appear in
  increasing numerical order of their label values (for the le or the quantile
  label, respectively).

--]]

local format_histogram = function(name, metric, value, ...)
    local labels = metric[2] and format_labels(metric, ...) or {}
    local nl, nb = metric[2] and #metric[2] or 0, #metric[5]

    for i=1, nb+1 do
        labels[nl+1] = format([[le=%q]], metric[5][i] or "+Inf")
        add([[%s_bucket{%s} %s]], name, concat(labels, ","), value[i])
    end

    if #labels > 1 then
        labels = concat(labels, ",", 1, #labels-1)
        add([[%s_count{%s} %s]], name, labels, value[nb+1])
        add([[%s_sum{%s} %s]], name, labels, value[nb+2])
    else
        add([[%s_count %s]], name, value[nb+1])
        add([[%s_sum %s]], name, value[nb+2])
    end
end

format_typ[typ_counter] = function(name, metric, typ)
    add([[# TYPE %s %s]], name, typ or "counter")
    if type(metric[3]) == "table" then
        recurse_action(name, metric, metric[3], format_counter)
    else
        format_counter(name, metric, metric[3])
    end
end

format_typ[typ_gauge] = function(name, metric)
    format_typ[typ_counter](name, metric, "gauge")
end

format_typ[typ_histogram] = function(name, metric)
    add([[# TYPE %s histogram]], name)
    if metric[2] then
        recurse_action(name, metric, metric[3], format_histogram)
    else
        format_histogram(name, metric, metric[3])
    end
end

return function(data)
    clear_tab(output)

    for name, metric in pairs(data) do
        help(name, metric)
        format_typ[metric[1]](name, metric)
    end

    return concat(output, "\n")
end
