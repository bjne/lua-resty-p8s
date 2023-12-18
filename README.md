# prometheus (p8s) metric library for nginx/openresty

This is a Lua library that can be used with Nginx to keep track of metrics and
expose them on a separate web page to be pulled by
[Prometheus](https://prometheus.io).

## Installation

copy the contents of the lib directory recursively to a path available in
`lua_package_path`

openresty users will find this library in [opm](https://opm.openresty.org/).

## Quick start guide

To track request latency broken down by server name and request count
broken down by server name and status, add the following to the `http` section
of `nginx.conf`:

```
lua_shared_dict resty_p8s 10M;

lua_package_path "/path/to/lua-resty-p8s/lib/?.lua;;";

init_by_lua_block {
    _G.p8s = require "resty.p8s"
}

init_worker_by_lua_block {
    -- set con to nomerge as its generated on request
    _G.con = p8s.gauge("con", "state"):help("http connections"):merge(false)
    _G.req = p8s.counter("req", "host", "status"):help("http requests")
    _G.lat = p8s.histogram("lat", "host"):help("request latency")
}

log_by_lua_block {
    req(1, ngx.var.server_name, ngx.var.status)
    lat(ngx.var.request_time, ngx.var.server_name)
}

server {
    location /enable_internal_metrics {
        -- enables internal metrics for a spesific worker (or true for all)
        content_by_lua_block {
            p8s.enable_internal_metrics(true)
        }
    }

    location /disable_internal_metrics {
        -- disables internal metrics for a spesific worker (or true for all)
        content_by_lua_block {
            p8s.disable_internal_metrics(true)
        }
    }

    location /no_internal_metrics {
        content_by_lua_block {
            p8s(false)
        }
    }

    location /reset_internal_metrics_for_all_workers {
        content_by_lua_block {
            p8s.reset_internal_metrics(true)
        }
    }

    location /ordered_output_with_internal_metrics {
        content_by_lua_block { p8s(true, true) }
    }
}
```

* configures a shared dictionary with the default name `resty_p8s`
* registers a gauge called `con` with one label `state`
* registers a counter called `req` with two labels: `host` and `status`
* registers a histogram called `lat` with one label `host`
* on each HTTP request measures its latency, recording it in the histogram and
  increments the counter, setting current server name as the `host` label and
  HTTP status code as the `status` label.

Last step is to configure a separate server that will expose the metrics.

```
server {
    listen 9145;
    allow 10.0.0.0/8;
    deny all;

    location /metrics {
        content_by_lua_block {
            con(ngx.var.connections_reading, "reading")
            con(ngx.var.connections_waiting, "waiting")
            con(ngx.var.connections_writing, "writing")
            p8s()
        }
    }
}
```

Metrics will be available at `http://your.nginx:9145/metrics`. Note that the
gauge metric in this example contains values obtained from nginx global state,
so they get set immediately before metrics are returned to the client.

## API reference

### init()

**syntax:** require("p8s").init(*sync_interval or dict_name*, *sync_interval or dict_name*)

Initializes the module. This should be called once from `init` and/or `init_worker`
If called from `init` sync-timers are not started, but will be autostarted first
time a metric is created in any other phase (or .init is called again without
argument needed in init_worker)

* `dict_name` is the name of the nginx shared dictionary which will be used to
  store all metrics. Defaults to `lua_resty_p8s` if not specified.
  if can also be specified as a reference to a shared dict
* `sync_interval`): sets per-worker counter sync interval in seconds, default 1

Returns a `p8s` object that should be used to register metrics.

Example:
```
init_worker_by_lua_block {
    p8s = require("p8s").init("i_want_to_use_my_own_dict_name_for_some_reason")
}
```

### p8s.counter()

**syntax:** p8s.counter(*name*, *label_name*, ...)

* `name` is the name of the metric.
* `label_name` list of label names. Optional.

[Naming section](https://prometheus.io/docs/practices/naming/) of Prometheus
documentation provides good guidelines on choosing metric and label names.

Returns a `counter` object that can later be incremented.

Example:
```
init_worker_by_lua_block {
    p8s = require("p8s").init()
    metric_bytes = p8s.counter("nginx_http_request_size_bytes")
    metric_requests = p8s.counter("nginx_http_requests_total", "host", "status")
}
```

### p8s.gauge()

**syntax:** p8s.gauge(*name*, *label_name*, ...)

* `name` is the name of the metric.
* `label_name` list of label names. Optional.

Returns a `gauge` object that can later be set.

Example:
```
init_worker_by_lua_block {
    p8s = require("p8s").init()
    metric_connections = p8s.gauge("nginx_http_connections", "state")
}
```

### p8s.histogram()

**syntax:** p8s.histogram(*name*, *buckets*, *label_name*, ...)

* `name` is the name of the metric.
* `buckets` is an array of numbers defining bucket boundaries. Optional,
  defaults to 20 latency buckets covering a range from 5ms to 10s (in seconds).
* `label_name` list of label names. Optional


Returns a `histogram` object that can later be used to record samples.

Example:
```
init_worker_by_lua_block {
    p8s = require("p8s").init()
    metric_latency = p8s.histogram("nginx_http_request_duration_seconds", "host"}
    metric_response_sizes = p8s.histogram(
        "nginx_http_response_size_bytes", {10,100,1000,10000,100000,1000000}
    )
}
```

### p8s()

**syntax:** p8s()

Presents all metrics in a text format compatible with Prometheus. This should be
called in
[content_by_lua_block](https://github.com/openresty/lua-nginx-module#content_by_lua_block)
to expose the metrics on a separate HTTP page.

Example:
```
location /metrics {
    content_by_lua_block { p8s() }
}
```

### counter:incr() or counter()

**syntax:** counter:incr(*value*, *label_value*, ...)

Increments a previously registered counter.

* `value` is a value that should be added to the counter. Defaults to 1
* `label_value` zero or more label values

The number of label values should match the number of label names defined when
the counter was registered using `p8s.counter()`. No label values should
be provided for counters with no labels.

Example:
```
log_by_lua_block {
    metric_bytes(ngx.var.request_length)
    metric_requests(1, ngx.var.server_name, ngx.var.status)
}
```

### gauge:set() or gauge()

**syntax:** gauge:set(*value*, *label_value*, ...)

Sets the current value of a previously registered gauge.

* `value` is a value that the gauge should be set to. Required.
* `label_value` zero or more label values

### histogram:observe() or histogram()

**syntax:** histogram:observe(*value*, *label_value*, ...)

Records a value in a previously registered histogram.

* `value` is a value that should be recorded. Required.
* `label_value` zero or more label values

Example:
```
log_by_lua_block {
    metric_latency(ngx.var.request_time, ngx.var.server_name)
    metric_response_sizes(ngx.var.bytes_sent)
}
```

### (gauge or counter or histogram):reset(*worker*)

**syntax:** (gauge or counter or histogram):reset(*worker*)

Resets a metric to zero for current worker by default

* `worker` can be null for current worker, a id or `true` for all workers

`reset` returns self, so it can be nested like

Example:
```
    gauge:reset():set(10, "foo")
```

### (gauge or counter or histogram):help(*help*)

**syntax:** (gauge or counter or histogram):help(*help*)

Sets a HELP text for current metric, if that is something you want to waste bytes on

* `help` text, nil to clear current help

### (gauge or counter or histogram):labels(*label,...)

**syntax:** (gauge or counter or histogram):labels(*label*, ...)

Sets default labels for a metric

Example:
```
    local counter = p8s.counter("counter", "worker", "event"):labels(ngx.worker.id())
    counter(1, "some event")

    local counter2 = p8s.counter("counter", "something", "event"):labels(nil, "some event")
    counter(1, "something")
```

## Testing

cpan Test::Nginx Test::Nginx::Socket

./test.sh

## What is different compared to alternatives

This module uses LuaJIT serialization instead of pure shm to synchronize
metrics between workers. This means all counter updates are only done in
the local lua VM, and cross worker updates are a single shm write/interval

Rendering of prometheus output format is nworkers shm gets, and a local
merge. This should perform well when using multiple counters

Metrics are garbagecollected, so no need to delete them, just let the lua gc
take care of it. Keep in mind tho, that you need to keep a reference.

On reload (currenly) data is loaded from shm, but unless the same metric
if created again, garbagecollection may currently remove the data before
its recreated. Creating metrics in `init_worker` will mitigate this issue
