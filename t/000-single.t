# vim:set ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket 'no_plan';

our $http_config = <<'_EOC_';
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";


    init_worker_by_lua_block {
        p8s = require "resty.p8s"
        gauge = p8s.gauge("gauge")
        counter = p8s.counter("counter")
        histogram = p8s.histogram("histogram")
    }
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: basic
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
counter 0 0
# TYPE gauge gauge
gauge 0 0
# TYPE histogram histogram
histogram_bucket{le="0.05"} 0
histogram_bucket{le="0.1"} 0
histogram_bucket{le="0.2"} 0
histogram_bucket{le="0.5"} 0
histogram_bucket{le="1"} 0
histogram_bucket{le="+Inf"} 0
histogram_count 0
histogram_sum 0

=== TEST 2: increment
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            counter()
            gauge(10)
            histogram(0.25)
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body eval
# TYPE counter counter
# counter 1 \d+
# # TYPE gauge gauge
# gauge 10 \d+
# # TYPE histogram histogram
# histogram_bucket{le="0.05"} 0
# histogram_bucket{le="0.1"} 0
# histogram_bucket{le="0.2"} 0
# histogram_bucket{le="0.5"} 1
# histogram_bucket{le="1"} 1
# histogram_bucket{le="+Inf"} 1
# histogram_count 1
# histogram_sum 0.25

=== TEST 3: labels
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_worker_by_lua_block {
        p8s = require "resty.p8s"
        gauge = p8s.gauge("gauge", "label1", "label2")
        counter = p8s.counter("counter", "label1", "label2")
        histogram = p8s.histogram("histogram", "label1", "label2")
    }
--- config
    location /p8s {
        content_by_lua_block {
            counter()
            gauge(10)
            histogram(0.25)
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter{label1="null",label2="null"} 1
# TYPE gauge gauge
gauge{label1="null",label2="null"} 10
# TYPE histogram histogram
histogram_bucket{label1="null",label2="null",le="0.05"} 0
histogram_bucket{label1="null",label2="null",le="0.1"} 0
histogram_bucket{label1="null",label2="null",le="0.2"} 0
histogram_bucket{label1="null",label2="null",le="0.5"} 1
histogram_bucket{label1="null",label2="null",le="1"} 1
histogram_bucket{label1="null",label2="null",le="+Inf"} 1
histogram_count{label1="null",label2="null"} 1
histogram_sum{label1="null",label2="null"} 0.25

=== TEST 4: internal metrics
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_worker_by_lua_block {
        p8s = require "resty.p8s".init(0.1)
    }
--- config
    location /p8s {
        content_by_lua_block {
            ngx.sleep(0.2)
            p8s(true, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE resty_p8s_counter counter
resty_p8s_counter{worker="0",event="build dict"} 2
# TYPE resty_p8s_gauge gauge
resty_p8s_gauge{worker="0",event="data size"} 157
resty_p8s_gauge{worker="0",event="dict keys"} 7
resty_p8s_gauge{worker="0",event="dict size"} 102

=== TEST 5: no internal metrics
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_worker_by_lua_block {
        p8s = require "resty.p8s".init(0.1)
    }
--- config
    location /p8s {
        content_by_lua_block {
            ngx.sleep(0.2)
            p8s(false, true)
            ngx.say("hello p8s")
        }
    }
--- request
GET /p8s
--- response_body_like chomp
hello p8s
