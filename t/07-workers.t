# vim:set ts=4 sw=4 et fdm=marker:
BEGIN {
    $ENV{TEST_NGINX_REUSE_PORT} = 1;
}

use Test::Nginx::Socket 'no_plan';

master_on();
workers(4);

#repeat_each(10);

our $http_config = <<'_EOC_';
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_by_lua_block {
        p8s = require "resty.p8s"
    }

    init_worker_by_lua_block {
        gauge = p8s.gauge("gauge", "worker")
        counter = p8s.counter("counter", "worker")
        histogram = p8s.histogram("histogram", "worker")
        gauge(10, ngx.worker.id())
        counter(1, ngx.worker.id())
        histogram(0.25, ngx.worker.id())
        p8s.sync()
    }
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: multiple workers metrics
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter{worker="0"} 1
counter{worker="1"} 1
counter{worker="2"} 1
counter{worker="3"} 1
# TYPE gauge gauge
gauge{worker="0"} 10
gauge{worker="1"} 10
gauge{worker="2"} 10
gauge{worker="3"} 10
# TYPE histogram histogram
histogram_bucket{worker="0",le="0.05"} 0
histogram_bucket{worker="0",le="0.1"} 0
histogram_bucket{worker="0",le="0.2"} 0
histogram_bucket{worker="0",le="0.5"} 1
histogram_bucket{worker="0",le="1"} 1
histogram_bucket{worker="0",le="+Inf"} 1
histogram_count{worker="0"} 1
histogram_sum{worker="0"} 0.25
histogram_bucket{worker="1",le="0.05"} 0
histogram_bucket{worker="1",le="0.1"} 0
histogram_bucket{worker="1",le="0.2"} 0
histogram_bucket{worker="1",le="0.5"} 1
histogram_bucket{worker="1",le="1"} 1
histogram_bucket{worker="1",le="+Inf"} 1
histogram_count{worker="1"} 1
histogram_sum{worker="1"} 0.25
histogram_bucket{worker="2",le="0.05"} 0
histogram_bucket{worker="2",le="0.1"} 0
histogram_bucket{worker="2",le="0.2"} 0
histogram_bucket{worker="2",le="0.5"} 1
histogram_bucket{worker="2",le="1"} 1
histogram_bucket{worker="2",le="+Inf"} 1
histogram_count{worker="2"} 1
histogram_sum{worker="2"} 0.25
histogram_bucket{worker="3",le="0.05"} 0
histogram_bucket{worker="3",le="0.1"} 0
histogram_bucket{worker="3",le="0.2"} 0
histogram_bucket{worker="3",le="0.5"} 1
histogram_bucket{worker="3",le="1"} 1
histogram_bucket{worker="3",le="+Inf"} 1
histogram_count{worker="3"} 1
histogram_sum{worker="3"} 0.25

=== TEST 2: multiple workers internal metrics
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_worker_by_lua_block {
        p8s = require "resty.p8s"
        p8s.sync()
    }
--- config
    location /p8s {
        content_by_lua_block {
            p8s(true, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE resty_p8s_counter counter
resty_p8s_counter{worker="0",event="build dict"} 2
resty_p8s_counter{worker="1",event="build dict"} 2
resty_p8s_counter{worker="2",event="build dict"} 2
resty_p8s_counter{worker="3",event="build dict"} 2
# TYPE resty_p8s_gauge gauge
resty_p8s_gauge{worker="0",event="data size"} 157
resty_p8s_gauge{worker="0",event="dict keys"} 7
resty_p8s_gauge{worker="0",event="dict size"} 102
resty_p8s_gauge{worker="1",event="data size"} 157
resty_p8s_gauge{worker="1",event="dict keys"} 7
resty_p8s_gauge{worker="1",event="dict size"} 102
resty_p8s_gauge{worker="2",event="data size"} 157
resty_p8s_gauge{worker="2",event="dict keys"} 7
resty_p8s_gauge{worker="2",event="dict size"} 102
resty_p8s_gauge{worker="3",event="data size"} 157
resty_p8s_gauge{worker="3",event="dict keys"} 7
resty_p8s_gauge{worker="3",event="dict size"} 102

=== TEST 3: multiple workers multiple requests
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_worker_by_lua_block {
        p8s = require "resty.p8s"
    }
--- config
    location /t {
        content_by_lua_block {
            counter = p8s.counter("counter", "worker")
            counter(1, ngx.worker.id())
            p8s.sync()
        }
    }
    location /p8s {
        content_by_lua_block {
            for _=1,40 do
                local tcp = ngx.socket.tcp()
                tcp:connect("127.0.0.1", "$TEST_NGINX_SERVER_PORT")

                tcp:send("GET /t HTTP/1.0\r\n\r\n")
            end

            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body eval
qr/^# TYPE counter counter
counter\{worker="0"\} \d+
counter\{worker="1"\} \d+
counter\{worker="2"\} \d+
counter\{worker="3"\} \d+$/

=== TEST 4: multiple workers multiple requests, same label
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_worker_by_lua_block {
        p8s = require "resty.p8s"
        counter = p8s.counter("counter", "worker")
    }
--- config
    location /t {
        content_by_lua_block {
            counter(1, 0)
            p8s.sync()
        }
    }
    location /p8s {
        content_by_lua_block {
            for _=1,40 do
                local tcp = ngx.socket.tcp()
                tcp:connect("127.0.0.1", "$TEST_NGINX_SERVER_PORT")

                tcp:send("GET /t HTTP/1.0\r\n\r\n")
                tcp:receive()
            end

            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter{worker="0"} 40
