# vim:set ts=4 sw=4 et fdm=marker:
BEGIN {
    $ENV{TEST_NGINX_REUSE_PORT} = 1;
}

use Test::Nginx::Socket 'no_plan';

master_on();
workers(4);

#repeat_each(10);

our $http_config = <<'_EOC_';
    lua_shared_dict different_dict 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_by_lua_block {
        p8s = require "resty.p8s".init("different_dict")
    }

    init_worker_by_lua_block {
        counter = p8s.counter("counter", "worker")
        counter(1, ngx.worker.id())
        p8s.sync()
    }
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: different shm
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

=== TEST 2: sync interval
--- http_config
    lua_shared_dict resty_p8s 10M;
    lua_package_path "$prefix/../../lib/?.lua;;";

    init_by_lua_block {
        p8s = require "resty.p8s".init(5)
    }

    init_worker_by_lua_block {
        counter = p8s.counter("counter", "worker")
        counter(1, ngx.worker.id())
        p8s.sync()
    }
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
