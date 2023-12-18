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
        counter = p8s.counter("counter", "worker"):merge(false)
        counter(1, ngx.worker.id())
        p8s.sync()
    }
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: nomerge
--- http_config eval: $::http_config
--- config
    location /p8s {
        content_by_lua_block {
            p8s(false, true)
        }
    }
--- request
GET /p8s
--- response_body eval
qr/# TYPE counter counter
counter\{worker="\d+"\} 1/
