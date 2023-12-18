# vim:set ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket 'no_plan';
workers(4);
master_on();

no_long_string();
run_tests();

__DATA__

=== TEST 1: internal metrics
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

=== TEST 2: disable internal metrics
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";


    init_worker_by_lua_block {
        p8s = require "resty.p8s"
        p8s.disable_internal_metrics()
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
--- response_body eval
qr/^\n$/
