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
        p8s.init(0.1)
        counter = p8s.counter("counter", "worker")
        counter(ngx.worker.id())
        if ngx.worker.id() % 2 == 0 then
            counter:reset()
        end
        p8s.sync()
    }
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: reset local
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
counter{worker="1"} 1
counter{worker="3"} 1

=== TEST 1: reset spesific worker
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            counter:reset(1)
            p8s.sync()
            ngx.sleep(0.2)
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
counter{worker="3"} 1

=== TEST 1: reset all
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            counter:reset(true)
            p8s.sync()
            ngx.sleep(0.2)
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body
# TYPE counter counter
