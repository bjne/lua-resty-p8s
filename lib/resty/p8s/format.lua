local concat = table.concat
local insert = table.insert
local format = string.format
local sort = table.sort

local clear_tab do local ok
    ok, clear_tab = pcall(require, "table.clear")
    if not ok then
        ngx.log(ngx.ERR, "performance degradation: table.clear unavailable")
        clear_tab=function(t) for k in pairs(t) do t[k]=nil end end
    end
end

local recurse_action do
    function recurse_action(name, metric, t, f, ordered_output, depth, ...)
        depth = depth or #metric[2]
        local order = ordered_output and {}

        if type(t) ~= "table" then
            ngx.log(ngx.ERR, "data problem, not a table: ", name)

            return
        end

        for k,v in pairs(t) do
            if ordered_output then
                insert(order, k)
            elseif depth==1 then
                f(name, metric, v, k, ...)
            else
                recurse_action(name, metric, v, f, ordered_output, depth-1, k, ...)
            end
        end

        if not ordered_output then
            return
        end

        for _,k in ipairs(sort(order) or order) do
            if depth == 1 then
                f(name, metric, t[k], k, ...)
            else
                recurse_action(name, metric, t[k], f, ordered_output, depth-1, k, ...)
            end
        end
    end
end

local typ_counter, typ_gauge, typ_histogram = 1,2,3

local output, format_typ = {}, {}

local add = function(...)
    insert(output, format(...))
end

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

format_typ[typ_counter] = function(name, metric, ordered_output, typ)
    add([[# TYPE %s %s]], name, typ or "counter")
    if type(metric[3]) == "table" then
        recurse_action(name, metric, metric[3], format_counter, ordered_output)
    else
        format_counter(name, metric, metric[3])
    end
end

format_typ[typ_gauge] = function(name, metric, ordered_output)
    format_typ[typ_counter](name, metric, ordered_output, "gauge")
end

format_typ[typ_histogram] = function(name, metric, ordered_output)
    add([[# TYPE %s histogram]], name)
    if metric[2] then
        recurse_action(name, metric, metric[3], format_histogram, ordered_output)
    else
        format_histogram(name, metric, metric[3])
    end
end

local format_metric = function(name, metric, ordered_output)
    help(name, metric)
    format_typ[metric[1]](name, metric, ordered_output)
end

local order = {}

return function(data, ordered_output)
    clear_tab(output)

    for name, metric in pairs(data) do
        if ordered_output then
            insert(order, name)
        else
            format_metric(name, metric)
        end
    end

    if ordered_output then
        for _, name in ipairs(sort(order) or order) do
            format_metric(name, data[name], true)
        end

        clear_tab(order)
    end

    return concat(output, "\n")
end
